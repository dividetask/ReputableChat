# frozen_string_literal: true

require "base64"
require "digest"
require "ed25519"
require "json"
require_relative "operator"
require_relative "cryptography/canonical"

module ReputableChat
  # The host account: this server's own. Every chat server has one, and it is
  # the same account as the agnostic server's beside it -- one account per
  # server, whatever apps it runs. The agnostic server makes it on first boot
  # and keeps its working seed outside both apps (host/ at the root of the
  # repository); the chat reads that seed (host_seed in config/server.yml) to
  # sign as it, and refuses to run if the seed's key is
  # not the account the agnostic server names.
  #
  # A new account starts with it as a friend, beside the genesis account, and
  # it is what the chat announces itself with (Chain::Service).
  class Host
    class Missing < StandardError; end
    class Mismatch < StandardError; end

    attr_reader :account, :pubkey, :payload, :signature, :hash, :declaration

    def self.join(chain, seed_path:)
      unless File.exist?(seed_path)
        raise Missing, "no host seed at #{seed_path}. The agnostic server writes it on its first boot; " \
                       "start that first, or point host_seed (HOST_SEED) at its data directory."
      end

      keys = Operator.derive(Operator.seed_phrase(path: seed_path))
      theirs = chain.host
      unless keys["pubkey"] == theirs["pubkey"]
        raise Mismatch, "the seed at #{seed_path} derives #{keys['pubkey']}, but the agnostic server at " \
                        "#{chain.url} signs as #{theirs['pubkey']}. A chat server shares its agnostic " \
                        "server's account: point host_seed at that server's host.seed."
      end

      new(theirs, private_key: keys["private_key"])
    end

    # `wire` is the agnostic server's GET /api/host: its id, its working key,
    # and its current identity declaration.
    def initialize(wire, private_key: nil)
      @account = wire.fetch("id")
      @pubkey = wire.fetch("pubkey")
      record = wire.fetch("declaration")
      @payload = record.fetch("payload")
      @signature = record.fetch("signature")
      @hash = record.fetch("hash")
      @declaration = JSON.parse(@payload)
      # Signed in-process: the chat signs every upload as this account, too
      # often to start Node for each as Operator does.
      @signing_key = private_key && Ed25519::SigningKey.new(Base64.urlsafe_decode64(pad(private_key)))
    end

    def handle = declaration["title"]
    def icon = declaration["file"]&.first

    # What a client is given: the account and its declaration, enough to show
    # it as a default friend before anything else is fetched.
    def to_h = { "account" => account, "payload" => payload, "signature" => signature, "hash" => hash }

    # A report for the agnostic server that this app did or did not reach
    # another server's account: [payload, signature]. Not a record; it never
    # leaves this machine.
    def contact_report(account, reached:, at: Time.now.to_i)
      sign({ "purpose" => "reputablechat:contact:v1", "account" => account, "reached" => reached, "ts" => at.to_i })
    end

    # The headers that make a request to the agnostic server a signed upload,
    # which it requires before it takes records: the account, its working key,
    # a timestamp and a signature over those with the method, path and the
    # body's SHA-256. The agnostic server's UploadAuth checks them.
    UPLOAD = "reputablechat:upload:v1"

    def upload_headers(method, path, body, at: Time.now.to_i)
      message = [UPLOAD, method.to_s.upcase, path, at.to_i.to_s, Digest::SHA256.hexdigest(body.to_s.b)].join("\n")
      { "X-Reputablechat-Account" => account, "X-Reputablechat-Key" => pubkey,
        "X-Reputablechat-Ts" => at.to_i.to_s, "X-Reputablechat-Signature" => sign_bytes(message) }
    end

    # Signs a payload as the host account: [canonical payload, signature].
    def sign(payload)
      canonical = Cryptography::Canonical.dump(payload)
      [canonical, sign_bytes(canonical)]
    end

    private

    # Ed25519 over the bytes, as unpadded base64url.
    def sign_bytes(message)
      raise Missing, "this host account was loaded without its seed and cannot sign" unless @signing_key

      Base64.urlsafe_encode64(@signing_key.sign(message.b), padding: false)
    end

    def pad(b64) = b64 + ("=" * ((4 - (b64.length % 4)) % 4))
  end
end
