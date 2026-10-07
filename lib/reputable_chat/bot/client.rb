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
      class Conflict < Error; end    # 409: a used seq, or a stale config revision
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

      def defaults     = request(:get, "/api/defaults")
      def emote_kinds  = request(:get, "/api/emote-kinds")
      def limits       = request(:get, "/api/limits")
      def genesis      = request(:get, "/api/genesis")
      def host         = request(:get, "/api/host")["host"]
      def challenge    = request(:post, "/api/challenge", {}).fetch("nonce")

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

      # --- chain records ----------------------------------------------------
      #
      # Who somebody is, and what they think of everybody else: two records,
      # because they change on completely different clocks. A reaction moves an
      # attestation; nothing about a reaction touches a display name.

      def identity(pubkey)   = request(:get, "/api/identity/#{pubkey}")["identity"]
      def identities(pubkeys) = request(:post, "/api/identity/batch", "pubkeys" => pubkeys)["identities"]

      def attestation(pubkey)   = request(:get, "/api/attestation/#{pubkey}")["attestation"]

      # One round trip for a whole traversal level. A seven-deep walk done one
      # fetch at a time would be hundreds of sequential requests.
      def attestations(pubkeys)
        request(:post, "/api/attestation/batch", "pubkeys" => pubkeys)["attestations"]
      end

      def publish_identity(identity:, revision:, handle:, bio:, ack:, icon: nil)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.identity(
          pubkey: identity.pubkey, revision: revision, handle: handle, bio: bio,
          icon: icon, ack: ack, issued_at: issued_at
        )

        request(:put, "/api/identity",
                "revision" => revision, "handle" => handle, "bio" => bio, "icon" => icon,
                "ack" => ack, "ts" => issued_at, "signature" => identity.sign(payload))
      end

      def publish_attestation(identity:, revision:, scores:, derived:, ack:)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.attestation(
          pubkey: identity.pubkey, revision: revision, scores: scores,
          derived: derived, ack: ack, issued_at: issued_at
        )

        request(:put, "/api/attestation",
                "revision" => revision, "scores" => scores, "derived" => derived,
                "ack" => ack, "ts" => issued_at, "signature" => identity.sign(payload))
      end

      # --- the room that is not a room --------------------------------------

      def messages  = request(:get, "/api/messages")["messages"]
      def reactions = request(:get, "/api/emotes")["emotes"]

      # Returns the record hash. Everything that later points at this message
      # -- a reply, a reaction, an ack -- names it, and the server derives the
      # same one from the same two strings, so a mismatch means the bytes it
      # stored are not the bytes that were signed.
      def send_message(identity:, body:, ack:, reply_to: nil)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.message(
          pubkey: identity.pubkey, body: body, ack: ack,
          issued_at: issued_at, reply_to: reply_to
        )

        deliver_record(identity, payload, "/api/message",
                       "body" => body, "ack" => ack, "ts" => issued_at,
                       "reply_to" => reply_to)
      end

      def send_emote(identity:, message:, emote:, ack:)
        issued_at = Time.now.to_i
        payload   = Cryptography::Payload.emote(
          pubkey: identity.pubkey, message: message, emote: emote,
          ack: ack, issued_at: issued_at
        )

        deliver_record(identity, payload, "/api/emote",
                       "message" => message, "emote" => emote, "ack" => ack,
                       "ts" => issued_at)
      end

      private

      def deliver_record(identity, payload, path, fields)
        canonical = Cryptography::Canonical.dump(payload)
        signature = identity.sign(payload)
        hash      = Cryptography::Record.digest(payload: canonical, signature: signature)

        stored = request(:post, path, fields.merge("signature" => signature))
        served = stored["hash"]

        if served && served != hash
          raise Error, "#{path}: the server hashed that record to #{served} and this client to #{hash}"
        end

        hash
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
