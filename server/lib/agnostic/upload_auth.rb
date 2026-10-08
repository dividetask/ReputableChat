# frozen_string_literal: true

require "digest"
require_relative "keys"
require_relative "record"
require_relative "view"

module Agnostic
  # Who may upload. A request that adds records -- POST /api/records and
  # POST /api/sync -- is signed by an account already on this server's chain,
  # with that account's current working or master key. Reading needs nothing.
  #
  # The signature covers the method, the path, a timestamp and the SHA-256 of
  # the body, so it cannot be moved to another request or another body, and
  # goes stale once the timestamp is further from the receiver's clock than
  # peers.max_clock_skew_seconds. A replay within that window re-sends the
  # same records, which the receiver already holds.
  module UploadAuth
    DOMAIN = "reputablechat:upload:v1"
    HEADERS = {
      account: "X-Reputablechat-Account", key: "X-Reputablechat-Key",
      ts: "X-Reputablechat-Ts", signature: "X-Reputablechat-Signature"
    }.freeze

    # Why a request could not be verified, and whether the account is simply
    # not on this server's chain yet (it can introduce itself and try again).
    class Refused < StandardError
      attr_reader :unknown_account

      def initialize(message, unknown_account: false)
        super(message)
        @unknown_account = unknown_account
      end
    end

    module_function

    def message(method, path, ts, body)
      [DOMAIN, method.to_s.upcase, path, ts.to_s, Digest::SHA256.hexdigest(body.to_s.b)].join("\n")
    end

    # The headers a signed upload carries.
    def headers(host, method, path, body, ts)
      signature = Keys.sign(host.signing_key, message(method, path, ts, body))
      { HEADERS[:account] => host.id, HEADERS[:key] => host.pubkey, HEADERS[:ts] => ts.to_s,
        HEADERS[:signature] => signature }
    end

    # The account that signed a request, or Refused.
    def verify!(env, store:, genesis:, now:, skew:)
      account, key, ts, signature = HEADERS.values.map { |name| env["HTTP_#{name.upcase.tr('-', '_')}"] }
      unless account && key && ts && signature
        raise Refused, "uploading records needs a request signed by an account on the chain (#{HEADERS.values.join(', ')})"
      end

      stamp = Integer(ts, exception: false)
      raise Refused, "the request's timestamp is more than #{skew} seconds from this server's clock" unless
        stamp && (stamp - now).abs <= skew

      declaration = Record.hash?(account) && store.fetch(account)
      unless declaration&.first_declaration?
        raise Refused.new("account #{account[0, 64]} is not on this server's chain; introduce it first (POST /api/introduce)",
                          unknown_account: true)
      end
      raise Refused, "#{key[0, 43]} is not a current key of #{account}" unless current_keys(account, store, genesis).include?(key)

      body = env["rack.input"].read.to_s
      env["rack.input"].rewind
      raise Refused, "the signature does not verify" unless
        Keys.verify(key, signature, message(env["REQUEST_METHOD"], env["PATH_INFO"], ts, body))

      account
    end

    # The account's newest working and master keys, as everything this server
    # holds sees them.
    def current_keys(account, store, genesis)
      view = Everything.new(store: store, histories: Histories.new(store), hashes: nil, genesis: genesis.digest)
      keys = view.keys(account)
      keys.current("pubkey") + keys.current("mpubkey")
    end

    # The chain as a whole rather than as one record sees it.
    class Everything < View
      def include?(_hash) = true
    end
  end
end
