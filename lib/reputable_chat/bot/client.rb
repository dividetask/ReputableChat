# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../cryptography/payload"
require_relative "../cryptography/canonical"
require_relative "../cryptography/record"

module ReputableChat
  module Bot
    # The bot's side of the API. Exactly what a browser does: ask for a
    # challenge, sign it, keep the session cookie, and send signed blobs.
    class Client
      class Error < StandardError; end
      class Conflict < Error; end    # 409: a used seq, or a stale config version
      class Unauthorized < Error; end

      NETWORK_ERRORS = [
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::EPIPE,
        Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError
      ].freeze

      RETRIES = 4

      # Net::HTTP, wrapped so a test can drive the same client against a Rack
      # app in-process. Everything above this line is protocol; everything in
      # here is sockets.
      class HttpTransport
        def initialize(base_url)
          @base = URI.parse(base_url.to_s.chomp("/"))
        end

        def call(verb, path, headers, body)
          uri   = URI.join("#{@base}/", path.sub(%r{\A/}, ""))
          klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(verb)
          req   = klass.new(uri)
          headers.each { |name, value| req[name] = value }
          req.body = body if body

          response = Net::HTTP.start(uri.hostname, uri.port,
                                     use_ssl: uri.scheme == "https",
                                     open_timeout: 10, read_timeout: 30) { |http| http.request(req) }

          [response.code.to_i, response.get_fields("Set-Cookie"), response.body.to_s]
        end
      end

      attr_reader :origin

      # `base_url` is where the bot dials; `origin` is what it signs. They are
      # usually the same, but the signed origin has to match the server's
      # configured `origin` exactly -- a bot reaching the same server through a
      # LAN address or a tunnel still has to sign the public URL, or every
      # login is rejected as a bad signature.
      def initialize(base_url:, origin: nil, logger: nil, transport: nil)
        @origin    = (origin || base_url).to_s.chomp("/")
        @logger    = logger
        @transport = transport || HttpTransport.new(base_url)
        @cookie    = nil
      end

      def defaults      = request(:get, "/api/defaults")
      def emote_config  = request(:get, "/api/emotes")
      def genesis       = request(:get, "/api/genesis")
      def challenge     = request(:post, "/api/challenge", {}).fetch("nonce")

      def log_in(identity)
        nonce     = challenge
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.login(
          pubkey: identity.pubkey, nonce: nonce, origin: @origin, issued_at: issued_at
        )

        request(:post, "/api/session",
                "pubkey" => identity.pubkey, "nonce" => nonce, "ts" => issued_at,
                "signature" => identity.sign(payload))
      end

      def register = request(:post, "/api/register", {})

      # A second client against the same server with its own cookie, for
      # acting as somebody else -- a voucher signing in to introduce a bot --
      # without logging the bot itself out.
      def fork
        self.class.new(base_url: nil, origin: @origin, logger: @logger, transport: @transport)
      end

      def config(pubkey)   = request(:get, "/api/config/#{pubkey}")["config"]
      def configs(pubkeys) = request(:post, "/api/config/batch", "pubkeys" => pubkeys)["configs"]

      def messages(room) = request(:get, "/api/room/#{room}/messages")["messages"]
      def reactions(room) = request(:get, "/api/room/#{room}/emotes")["emotes"]

      def publish_config(identity:, version:, profile:, ratings:)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.config(
          pubkey: identity.pubkey, version: version, profile: profile,
          ratings: ratings, issued_at: issued_at
        )

        request(:put, "/api/config",
                "version" => version, "profile" => profile, "ratings" => ratings,
                "ts" => issued_at, "signature" => identity.sign(payload))
      end

      # Returns the record hash, derived here from the same two strings the
      # server derives it from. Everything that later points at this message --
      # a reply, a reaction, an ack -- names that hash.
      def send_message(identity:, room:, seq:, prev:, body:, ack:, reply_to: nil)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.message(
          author: identity.pubkey, room: room, seq: seq, prev: prev,
          body: body, ack: ack, issued_at: issued_at, reply_to: reply_to
        )

        deliver_record(identity, payload, "/api/room/#{room}/message",
                       "seq" => seq, "prev" => prev, "ack" => ack, "body" => body,
                       "ts" => issued_at, "reply_to" => reply_to)
      end

      def send_emote(identity:, room:, message:, emote:, ack:)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.emote(
          author: identity.pubkey, room: room, message: message,
          emote: emote, ack: ack, issued_at: issued_at
        )

        deliver_record(identity, payload, "/api/room/#{room}/emote",
                       "message" => message, "emote" => emote, "ack" => ack,
                       "ts" => issued_at)
      end

      private

      def deliver_record(identity, payload, path, fields)
        canonical = Cryptography::Canonical.dump(payload)
        signature = identity.sign(payload)

        request(:post, path, fields.merge("signature" => signature))

        Cryptography::Record.digest(payload: canonical, signature: signature)
      end

      def request(verb, path, body = nil)
        attempt = 0

        begin
          deliver(verb, path, body)
        rescue *NETWORK_ERRORS => e
          attempt += 1
          raise Error, "#{verb.upcase} #{path}: #{e.class} after #{RETRIES} attempts" if attempt > RETRIES

          delay = 2**attempt
          @logger&.call("network error on #{path} (#{e.class}), retrying in #{delay}s")
          sleep delay
          retry
        end
      end

      def deliver(verb, path, body)
        headers = {}
        headers["Cookie"] = @cookie if @cookie
        headers["Content-Type"] = "application/json" if body

        status, cookies, text = @transport.call(verb, path, headers, body && JSON.generate(body))
        remember_cookie(cookies)

        interpret(status, text, verb, path)
      end

      # Roda's session cookie. Keeping it is the whole of "being logged in".
      def remember_cookie(cookies)
        return if cookies.nil? || cookies.empty?

        @cookie = cookies.map { |line| line.split(";").first }.join("; ")
      end

      def interpret(status, text, verb, path)
        parsed = begin
          JSON.parse(text.to_s)
        rescue JSON::ParserError
          {}
        end

        case status
        when 200..299 then parsed
        when 401 then raise Unauthorized, "#{verb.upcase} #{path}: #{parsed['error'] || 'not signed in'}"
        when 409 then raise Conflict, "#{verb.upcase} #{path}: #{parsed['error'] || 'conflict'}"
        else raise Error, "#{verb.upcase} #{path}: #{status} #{parsed['error'] || text}"
        end
      end
    end
  end
end
