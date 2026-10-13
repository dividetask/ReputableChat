# frozen_string_literal: true

require "json"
require "net/http"
require "socket"

module ReputableChat
  # The chat's line to its agnostic server, which holds the chain: it judges
  # every record against the rules, stores the valid ones, syncs with other
  # servers and says where each record stands. The chat checks nothing the
  # rules decide; it passes a record on and reads the answer.
  #
  # It talks to the agnostic server over that server's local listener: a Unix
  # socket in the host account's directory, which only processes able to read
  # the host account's phrase can open. There uploads need no signature, and
  # only there are nudges taken. The server opens it once it is live.
  #
  # See ../server/README.md for the API.
  class ChainClient
    class Unreachable < StandardError; end
    # Not answering yet: not listening, or answering 503 while it catches up
    # or is stopped for a chain split. Worth waiting for; anything else is not.
    class NotReady < Unreachable; end

    # What submitting a record came to: accepted, known (already held),
    # pending (waiting on records it acknowledges, listed in missing) or
    # refused (with the rules it breaks, in problems).
    Result = Struct.new(:status, :hash, :problems, :missing, keyword_init: true) do
      def accepted? = status == "accepted"
    end

    # Net::HTTP over a Unix socket: the same requests, a different wire.
    class SocketHTTP < Net::HTTP
      # Net::HTTP.new passes an address and a port; here the address is the
      # socket's path, and there is no port.
      def initialize(path, _port = nil)
        super("localhost", nil)
        @socket_path = path
      end

      def connect
        @socket = Net::BufferedIO.new(UNIXSocket.new(@socket_path), read_timeout: @read_timeout,
                                                                    write_timeout: @write_timeout,
                                                                    continue_timeout: @continue_timeout,
                                                                    debug_output: @debug_output)
        on_connect
      end
    end

    # The socket's path.
    attr_reader :socket

    def initialize(socket, http: nil)
      @socket = socket.to_s
      @http = http
    end

    # What error messages call it.
    def url = "the socket #{socket}"

    def genesis = get("/api/genesis")

    # The agnostic server's host account, which the chat shares.
    def host = get("/api/host")

    # The agnostic server's ratings of other accounts: account => the
    # reputation and trust it publishes, and what they came from (operator,
    # reachability, and nudges by app), each only when present.
    def ratings = get("/api/ratings")["ratings"]

    # Moves the agnostic server's rating of an account by this app's own
    # judgement: one nudge per app and account, replacing the last; "0" and
    # "0" takes it back. Decimals from -1 to 1, spelled as the rules spell
    # one. Answers the account's rating as it now stands.
    def nudge(app:, account:, reputation:, trust:)
      post("/api/nudges", { "app" => app, "account" => account, "reputation" => reputation, "trust" => trust })
    end

    def submit(payload, signature)
      result = post("/api/records", { "payload" => payload, "signature" => signature })["results"].first
      Result.new(status: result["status"], hash: result["hash"], problems: result["problems"] || [],
                 missing: result["missing"] || [])
    end

    # Records the server accepted after the cursor, oldest first, and the
    # cursor that follows them.
    def records_since(cursor, limit: 500)
      page = get("/api/records?since=#{Integer(cursor)}&limit=#{Integer(limit)}")
      [page["records"], page["next"]]
    end

    def record(hash) = get("/api/records/#{hash}", missing: nil)

    def states(hashes)
      return {} if hashes.empty?

      hashes.each_slice(256).each_with_object({}) do |slice, out|
        out.merge!(post("/api/states", { "hashes" => slice })["states"])
      end
    end

    def accounts(ids)
      return [] if ids.empty?

      ids.each_slice(256).flat_map { |slice| post("/api/accounts", { "accounts" => slice })["accounts"] }
    end

    def account(id) = get("/api/accounts/#{id}", missing: nil)

    def account_for(pubkey) = get("/api/keys/#{pubkey}")["account"]

    private

    def get(path, missing: :raise) = request(:get, path, nil, missing: missing)

    def post(path, body) = request(:post, path, body, missing: :raise)

    # An injected `http` answers (method, path, body) with [status, parsed
    # body], so a spec can put the server in the same process.
    def request(method, path, body, missing:)
      status, parsed = @http ? @http.call(method, path, body) : over_the_socket(method, path, body)
      return nil if status == 404 && missing.nil?
      return parsed if status.between?(200, 299)
      raise NotReady, "the agnostic server at #{url} is not live: #{parsed['error']}" if status == 503

      raise Unreachable, "the agnostic server at #{url} answered #{status} to #{path}: #{parsed['error']}"
    end

    def over_the_socket(method, path, body)
      request = method == :get ? Net::HTTP::Get.new(path) : Net::HTTP::Post.new(path)
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      http = SocketHTTP.new(socket)
      http.open_timeout = 5
      http.read_timeout = 30
      response = http.start { |h| h.request(request) }
      [response.code.to_i, JSON.parse(response.body.to_s.empty? ? "{}" : response.body)]
    rescue Errno::EACCES
      raise Unreachable, "this process may not open the agnostic server's local socket #{socket}: the chat must " \
                         "run as the user the agnostic server runs as"
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ENOTSOCK, Net::OpenTimeout => e
      raise NotReady, "the agnostic server's local socket #{socket} cannot be opened (#{e.class}). Start it " \
                      "(cd server && bundle exec puma): it opens the socket once it is live. Or set CHAIN_SOCKET."
    rescue JSON::ParserError
      raise Unreachable, "the agnostic server at #{url} did not answer #{path} with JSON"
    end
  end
end
