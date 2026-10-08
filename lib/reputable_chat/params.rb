# frozen_string_literal: true

require "bigdecimal"
require_relative "chain/record"

module ReputableChat
  # Input validation. Everything from a client is checked for type, length and
  # shape before it reaches cryptography, the database, or a payload builder.
  # Helpers return nil rather than raising, so a handler can reject in one
  # place.
  module Params
    # Control characters have no business in a username, room name or message
    # body. Tab, newline and carriage return are allowed through for bodies.
    CONTROL = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

    module_function

    def string(value, max:, min: 1)
      return nil unless value.is_a?(String)
      return nil unless value.valid_encoding?

      trimmed = value.strip
      return nil unless trimmed.bytesize.between?(min, max)
      return nil if trimmed.match?(CONTROL)

      trimmed
    end

    def integer(value, min: 0, max: 2**53)
      return nil unless value.is_a?(Integer) || value.is_a?(String)

      int = Integer(value, exception: false)
      int && int.between?(min, max) ? int : nil
    end

    def base64url(value, bytes:)
      return nil unless value.is_a?(String)
      return nil unless value.match?(/\A[A-Za-z0-9_-]+\z/)

      expected = (bytes * 4.0 / 3).ceil
      value.bytesize.between?(expected - 2, expected + 2) ? value : nil
    end

    def pubkey(value) = base64url(value, bytes: 32)
    def signature(value) = base64url(value, bytes: 64)

    # A record hash: SHA-256 of a record's canonical payload and signature.
    # This is what `ack`, `target` and `endorse` hold, and what an account ID is.
    RECORD_HASH = /\A[0-9a-f]{64}\z/

    def record_hash(value)
      return nil unless value.is_a?(String)

      value.match?(RECORD_HASH) ? value : nil
    end

    def array_of(value, max:, &block)
      return nil unless value.is_a?(Array)
      return nil if value.empty? || value.size > max

      mapped = value.map(&block)
      mapped.include?(nil) ? nil : mapped
    end

    # --- the vault ---------------------------------------------------------

    # The vault's ciphertext. The server cannot check the shape of what is
    # inside, so a byte bound is the only control it has -- and it is what
    # bounds the voted list in practice, since that is the part of a vault that
    # grows without limit.
    MAX_VAULT = 1_048_576

    def sealed(value, max: MAX_VAULT)
      return nil unless value.is_a?(String)
      return nil unless value.match?(/\A[A-Za-z0-9_-]+\z/)

      value.bytesize.between?(1, max) ? value : nil
    end

    # AES-GCM nonce: 96 bits, which is what WebCrypto expects and what the
    # counter construction is safe at.
    def iv(value) = base64url(value, bytes: 12)

    # A decimal string in its one spelling, as the rules define it (section 1),
    # within a range. The pattern is Chain::Record's, so there is one home for
    # what a decimal looks like.
    def decimal(value, min: -1, max: 1)
      return nil unless value.is_a?(String) && value.match?(Chain::Record::DECIMAL) && value != "-0"

      number = BigDecimal(value)
      number.between?(BigDecimal(min.to_s), BigDecimal(max.to_s)) ? value : nil
    end
  end
end
