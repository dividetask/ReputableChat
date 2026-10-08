# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module ReputableChat
  # The chat's line to its agnostic server, which holds the chain: it judges
  # every record against the rules, stores the valid ones, syncs with other
  # servers and says where each record stands. The chat checks nothing the
  # rules decide; it passes a record on and reads the answer.
  #
  # See server/README.md for the API.
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

    attr_reader :url

    def initialize(url, http: nil)
      @url = url.to_s.chomp("/")
      @http = http
    end

    def genesis = get("/api/genesis")

    # The agnostic server's host account, which the chat shares.
    def host = get("/api/host")

    # The agnostic server's ratings of other accounts: account => reputation,
    # trust, and whether set by hand or by reachability.
    def ratings = get("/api/ratings")["ratings"]

    # Tells the agnostic server whether this app reached another server's
    # account, so it counts toward that account's rating. Signed by the host
    # account the two share; see Host#contact_report.
    def report_contact(payload, signature) = post("/api/contacts", { "payload" => payload, "signature" => signature })

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

    # An injected `http` answers (method, url, body) with [status, parsed
    # body], so a spec can put the server in the same process.
    def request(method, path, body, missing:)
      status, parsed = @http ? @http.call(method, "#{url}#{path}", body) : over_the_network(method, path, body)
      return nil if status == 404 && missing.nil?
      return parsed if status.between?(200, 299)
      raise NotReady, "the agnostic server at #{url} is not live: #{parsed['error']}" if status == 503

      raise Unreachable, "the agnostic server at #{url} answered #{status} to #{path}: #{parsed['error']}"
    end

    def over_the_network(method, path, body)
      uri = URI("#{url}#{path}")
      request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 5, read_timeout: 30) { |h| h.request(request) }
      [response.code.to_i, JSON.parse(response.body.to_s.empty? ? "{}" : response.body)]
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout => e
      raise NotReady, "the agnostic server at #{url} cannot be reached (#{e.class}). " \
                         "Start it (cd server && bundle exec puma), or set CHAIN_URL."
    rescue JSON::ParserError
      raise Unreachable, "the agnostic server at #{url} did not answer #{path} with JSON"
    end
  end
end
