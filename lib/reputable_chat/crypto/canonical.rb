# frozen_string_literal: true

require "json"

module ReputableChat
  module Crypto
    # Deterministic serialization for anything that gets signed.
    #
    # The browser signs bytes and the server verifies bytes, so both sides have
    # to produce byte-identical output for the same object or every signature
    # fails. Keys are sorted, separators carry no whitespace, output is UTF-8.
    # This mirrors JSON.stringify over sorted keys in public/js/canonical.js --
    # the two must be changed together.
    module Canonical
      module_function

      def dump(object)
        JSON.generate(normalize(object))
      end

      def bytes(object)
        dump(object).b
      end

      def normalize(object)
        case object
        when Hash
          object.each_with_object({}) { |(k, v), out| out[k.to_s] = normalize(v) }
                .sort.to_h
        when Array   then object.map { |v| normalize(v) }
        when Symbol  then object.to_s
        when Float
          # Floats have no single textual form across languages. Anything that
          # needs to be signed must arrive as a string or an integer.
          raise ArgumentError, "refusing to canonicalize a Float: #{object}"
        else object
        end
      end
    end
  end
end
