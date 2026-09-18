# frozen_string_literal: true

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
    # This is what `ack`, `prev`, `reply_to` and an emote's target are, and it
    # is the same shape as a content-addressed image name minus the extension.
    RECORD_HASH = /\A[0-9a-f]{64}\z/

    def record_hash(value)
      return nil unless value.is_a?(String)

      value.match?(RECORD_HASH) ? value : nil
    end

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

      # A content-addressed image name: the SHA-256 of the bytes plus a sniffed
    # extension. Nothing else is a legal icon reference.
    ICON = /\A[0-9a-f]{64}\.(png|jpg|gif|webp)\z/

    def icon(value)
      return nil unless value.is_a?(String)

      value.match?(ICON) ? value : nil
    end

    MAX_USERNAME = 64
    MAX_BIO      = 280

    def profile(value)
      return nil unless value.is_a?(Hash)

      username = string(value["username"], max: MAX_USERNAME) or return nil

      bio = value["message"].to_s
      bio = bio.empty? ? "" : (string(bio, max: MAX_BIO) or return nil)

      image = value["icon"]
      return nil unless image.nil? || icon(image)

      { "username" => username, "message" => bio, "icon" => image }
    end

    # An emote must be one the server actually publishes, so an arbitrary
    # string can never be stored and rendered back to everyone.
    def emote(value, allowed:)
      return nil unless value.is_a?(String)

      allowed.include?(value) ? value : nil
    end

    MAX_SETTING_KEYS   = 100
    MAX_SETTING_DEPTH  = 4
    MAX_SETTING_STRING = 256
    MAX_VOTED          = 50_000

    # A sparse override tree mirroring config/reputation.yml. The server checks
    # only that it is a bounded structure of scalars -- it never interprets the
    # contents, which stay the client's business.
    def settings(value, depth: MAX_SETTING_DEPTH)
      return nil unless value.is_a?(Hash)
      return nil if value.size > MAX_SETTING_KEYS || depth.zero?

      value.each do |key, item|
        return nil unless key.is_a?(String) && key.bytesize <= 64

        case item
        when Hash                      then return nil unless settings(item, depth: depth - 1)
        when String                    then return nil if item.bytesize > MAX_SETTING_STRING
        when Numeric, true, false, nil then next
        else return nil
        end
      end

      value
    end

    # Record hashes of the comments this user has already emoted on, so one
    # vote per comment survives moving to another device.
    def voted(value)
      return nil unless value.is_a?(Array)
      return nil if value.size > MAX_VOTED

      value.all? { |entry| record_hash(entry) } ? value : nil
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
        # Optional so a config written before `cleared` existed still validates.
        return nil unless [nil, true, false].include?(rating["cleared"])
      end

      value
    end
  end
end
