# frozen_string_literal: true

require "bigdecimal"

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

    # --- chain records ------------------------------------------------------

    MAX_NOTE    = 2_000
    MAX_HANDLE  = 64
    MAX_BIO     = 280
    MAX_SCORES  = 10_000
    MAX_DERIVED = 50_000
    MAX_LABEL   = 64
    MAX_NOTES   = 1_000
    MAX_FILES   = 500
    MAX_PATH    = 256

    # A decimal string. Numbers that are signed never travel as JSON numbers:
    # canonical serialization refuses floats outright, because they have no
    # single textual form across languages, and the Blocked line is
    # `effective > 0`, which binary floating point cannot be trusted to land on.
    DECIMAL = /\A-?(0|[1-9]\d{0,6})(\.\d{1,18})?\z/

    def decimal(value, min: -1, max: 1)
      return nil unless value.is_a?(String) && value.match?(DECIMAL)

      number = BigDecimal(value)
      number.between?(BigDecimal(min.to_s), BigDecimal(max.to_s)) ? value : nil
    end

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

    def handle(value) = string(value, max: MAX_HANDLE)

    # Free text for a person reading the raw chain, which the software never
    # interprets. Bounded, because it rides along inside every record it is set
    # on and is signed there permanently. Absent and empty both mean nil, so
    # that an empty string and no note cannot produce two different signatures
    # for what a reader would call the same record.
    def note(value, max: MAX_NOTE)
      return nil if value.nil? || value.to_s.strip.empty?

      string(value, max: max)
    end

    def bio(value)
      return "" if value.nil? || value.to_s.empty?

      string(value, max: MAX_BIO)
    end

    # What one person publishes about everyone they have an opinion of:
    # a reputation and a trust multiplier, both decimal strings.
    #
    # The multiplier is clamped to -1..1 rather than left open. Above 1 it would
    # amplify a branch past the weight the ladder assigned it, and the ladder's
    # weights summing to (just under) 1 is what keeps an effective score inside
    # -1..1 without clamping.
    def scores(value, max_entries: MAX_SCORES)
      return nil unless value.is_a?(Hash)
      return nil if value.size > max_entries

      value.each do |target, entry|
        return nil unless pubkey(target)
        return nil unless entry.is_a?(Hash)
        return nil unless decimal(entry["reputation"])
        return nil unless decimal(entry["trust"])
      end

      value
    end

    # The author's own calculated scores, and the fingerprint of the parameters
    # they were computed under. The fingerprint is not optional: without it a
    # reader cannot tell whether the numbers mean anything to them, and taking
    # them anyway would mean silently adopting a stranger's settings.
    def derived(value)
      return nil unless value.is_a?(Hash)
      return nil unless integer(value["hops"], min: 0, max: 7)
      return nil unless record_hash(value["params"])

      scores = value["scores"]
      return nil unless scores.is_a?(Hash) && scores.size <= MAX_DERIVED

      scores.each do |target, score|
        return nil unless pubkey(target)
        return nil unless decimal(score)
      end

      value
    end

    # A release manifest: published path => sha256 of the bytes at it. Paths are
    # relative and cannot climb, since they name files the client will fetch.
    PATH = %r{\A[a-z0-9][a-z0-9._/-]*\z}i

    def files(value)
      return nil unless value.is_a?(Hash)
      return nil if value.empty? || value.size > MAX_FILES

      value.each do |path, digest|
        return nil unless path.is_a?(String) && path.bytesize <= MAX_PATH
        return nil unless path.match?(PATH) && !path.include?("..")
        return nil unless record_hash(digest)
      end

      value
    end

    def label(value) = string(value, max: MAX_LABEL)

    MAX_TITLE  = 120
    MAX_NOTICE = 16_000

    def title(value) = string(value, max: MAX_TITLE)

    # A notice body is the longest thing the chain carries on purpose. The
    # founding notice is a document, so the bound is generous -- but bounded,
    # because every record is stored, served and signed forever.
    def notice_body(value, max: MAX_NOTICE) = string(value, max: max)

    # One of the kinds the server publishes, never an arbitrary string.
    def notice_kind(value, allowed:)
      return nil unless value.is_a?(String)

      allowed.include?(value) ? value : nil
    end

    def notes(value)
      return "" if value.nil? || value.to_s.empty?

      string(value, max: MAX_NOTES)
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
