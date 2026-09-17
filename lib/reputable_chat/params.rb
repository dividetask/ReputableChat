# frozen_string_literal: true

module ReputableChat
  # Input validation.
  #
  # Everything arriving from a client is checked for type, length and shape
  # before it reaches the crypto layer, the database or the signed payload
  # builders. Each helper returns nil on anything it does not like rather than
  # raising, so a handler can reject the whole request in one place.
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

    def room(value)
      return nil unless value.is_a?(String)

      value.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/) ? value : nil
    end

    def array_of(value, max:, &block)
      return nil unless value.is_a?(Array)
      return nil if value.empty? || value.size > max

      mapped = value.map(&block)
      mapped.include?(nil) ? nil : mapped
    end

    # A ratings map is passed through to storage unparsed, but its shape is
    # still checked so a malformed blob cannot be stored and then break every
    # client that fetches it.
    def ratings(value, max_entries: 10_000)
      return nil unless value.is_a?(Hash)
      return nil if value.size > max_entries

      value.each do |target, rating|
        return nil unless pubkey(target)
        return nil unless rating.is_a?(Hash)
        return nil unless [true, false].include?(rating["friend"])
        return nil unless [true, false].include?(rating["reported"])
        return nil unless integer(rating["net_votes"], min: -1_000_000, max: 1_000_000)
      end

      value
    end
  end
end
