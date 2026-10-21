# frozen_string_literal: true

require "base64"
require "ed25519"

module Agnostic
  # Ed25519 keys and signatures written as base64url without padding.
  module Keys
    KEY_BYTES       = 32
    SIGNATURE_BYTES = 64

    module_function

    # Strict: the right length, and the one spelling that length has, so two
    # strings never name the same key.
    def decode(value, bytes)
      return nil unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+\z/)

      raw = Base64.urlsafe_decode64(value)
      raw.bytesize == bytes && encode(raw) == value ? raw : nil
    rescue ArgumentError
      nil
    end

    def encode(raw) = Base64.urlsafe_encode64(raw, padding: false)

    def key?(value) = !decode(value, KEY_BYTES).nil?

    def signature?(value) = !decode(value, SIGNATURE_BYTES).nil?

    def verify(pubkey, signature, message)
      key = decode(pubkey, KEY_BYTES)
      sig = decode(signature, SIGNATURE_BYTES)
      return false unless key && sig

      Ed25519::VerifyKey.new(key).verify(sig, message.b)
    rescue Ed25519::VerifyError, ArgumentError
      false
    end

    def sign(signing_key, message) = encode(signing_key.sign(message.b))

    def public_key(signing_key) = encode(signing_key.verify_key.to_bytes)
  end
end
