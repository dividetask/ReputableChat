# frozen_string_literal: true

require "ed25519"
require "base64"
require_relative "canonical"

module ReputableChat
  module Crypto
    # Ed25519 verification. The server only verifies; private keys exist solely in
    # the browser.
    module Signature
      PUBKEY_BYTES    = 32
      SIGNATURE_BYTES = 64

      class InvalidKey < StandardError; end

      module_function

      def verify(pubkey_b64:, signature_b64:, payload:)
        key = verify_key(pubkey_b64)
        sig = decode(signature_b64, SIGNATURE_BYTES)
        return false unless key && sig

        key.verify(sig, Canonical.bytes(payload))
      rescue Ed25519::VerifyError, ArgumentError
        false
      end

      def verify_key(pubkey_b64)
        raw = decode(pubkey_b64, PUBKEY_BYTES)
        raw && Ed25519::VerifyKey.new(raw)
      rescue Ed25519::VerifyError, ArgumentError
        nil
      end

      def valid_pubkey?(pubkey_b64)
        !verify_key(pubkey_b64).nil?
      end

      # Strict base64url, fixed length. Anything else is rejected before it
      # reaches the crypto library.
      def decode(value, expected_bytes)
        return nil unless value.is_a?(String)
        return nil unless value.match?(/\A[A-Za-z0-9_-]+\z/)

        raw = Base64.urlsafe_decode64(value)
        raw.bytesize == expected_bytes ? raw : nil
      rescue ArgumentError
        nil
      end

      def encode(raw) = Base64.urlsafe_encode64(raw, padding: false)
    end
  end
end
