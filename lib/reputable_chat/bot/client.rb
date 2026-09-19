# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../cryptography/payload"

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

      attr_reader :origin

      # `base_url` is where the bot dials; `origin` is what it signs. They are
      # usually the same, but the signed origin has to match the server's
      # configured `origin` exactly -- a bot reaching the same server through a
      # LAN address or a tunnel still has to sign the public URL, or every
      # login is rejected as a bad signature.
      def initialize(base_url:, origin: nil, logger: nil)
        @base   = URI.parse(base_url.to_s.chomp("/"))
        @origin = (origin || base_url).to_s.chomp("/")
        @logger = logger
        @cookie = nil
      end

      def defaults      = request(:get, "/api/defaults")
      def emote_config  = request(:get, "/api/emotes")
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

      def send_message(identity:, room:, seq:, prev:, body:, reply_to: nil)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.message(
          author: identity.pubkey, room: room, seq: seq, prev: prev,
          body: body, issued_at: issued_at, reply_to: reply_to
        )
        signature = identity.sign(payload)

        request(:post, "/api/room/#{room}/message",
                "seq" => seq, "prev" => prev, "body" => body, "ts" => issued_at,
                "reply_to" => reply_to, "signature" => signature)

        signature
      end

      def send_emote(identity:, room:, message:, emote:)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.emote(
          author: identity.pubkey, room: room, message: message,
          emote: emote, issued_at: issued_at
        )

        request(:post, "/api/room/#{room}/emote",
                "message" => message, "emote" => emote, "ts" => issued_at,
                "signature" => identity.sign(payload))
      end

      private

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
        uri = URI.join("#{@base}/", path.sub(%r{\A/}, ""))

        klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(verb)
        req   = klass.new(uri)
        req["Cookie"] = @cookie if @cookie
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        response = Net::HTTP.start(uri.hostname, uri.port,
                                   use_ssl: uri.scheme == "https",
                                   open_timeout: 10, read_timeout: 30) { |http| http.request(req) }

        remember_cookie(response)
        interpret(response, verb, path)
      end

      # Roda's session cookie. Keeping it is the whole of "being logged in".
      def remember_cookie(response)
        set = response.get_fields("Set-Cookie") or return

        @cookie = set.map { |line| line.split(";").first }.join("; ")
      end

      def interpret(response, verb, path)
        parsed = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end

        case response.code.to_i
        when 200..299 then parsed
        when 401 then raise Unauthorized, "#{verb.upcase} #{path}: #{parsed['error'] || 'not signed in'}"
        when 409 then raise Conflict, "#{verb.upcase} #{path}: #{parsed['error'] || 'conflict'}"
        else raise Error, "#{verb.upcase} #{path}: #{response.code} #{parsed['error'] || response.body}"
        end
      end
    end
  end
end
