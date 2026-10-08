# frozen_string_literal: true

require "json"

module Agnostic
  # Canonical JSON as section 1 of the rules defines it: keys sorted, no
  # whitespace, UTF-8, and no floating-point numbers.
  #
  # The server never re-serializes a payload it stores. It parses the bytes it
  # was given, serializes the result, and refuses the record unless the two are
  # identical -- which catches unsorted keys, whitespace, duplicate keys, "-0",
  # escaped characters that canonical form writes raw, and every float.
  module Canonical
    # Integers past this are not exact in JavaScript, so a browser would read
    # and re-serialize them as a different number.
    SAFE_INTEGER = (2**53) - 1

    class NotCanonical < StandardError; end

    module_function

    def dump(object) = JSON.generate(normalize(object))

    # The payload as an object, or NotCanonical saying why it is not one.
    def parse(text)
      raise NotCanonical, "payload is not a string" unless text.is_a?(String)

      text = text.dup.force_encoding(Encoding::UTF_8)
      raise NotCanonical, "payload is not valid UTF-8" unless text.valid_encoding?

      object = JSON.parse(text)
      raise NotCanonical, "payload is not a JSON object" unless object.is_a?(Hash)
      raise NotCanonical, "payload is not in canonical form" unless dump(object) == text

      object
    rescue JSON::ParserError
      raise NotCanonical, "payload is not JSON"
    rescue ArgumentError => e
      raise NotCanonical, e.message
    end

    def normalize(object)
      case object
      when Hash
        object.each_with_object({}) { |(k, v), out| out[k.to_s] = normalize(v) }.sort.to_h
      when Array then object.map { |v| normalize(v) }
      when Symbol then object.to_s
      when Float then raise ArgumentError, "payload holds a floating-point number"
      when Integer
        raise ArgumentError, "payload holds an integer JavaScript cannot represent" if object.abs > SAFE_INTEGER

        object
      else object
      end
    end
  end
end
