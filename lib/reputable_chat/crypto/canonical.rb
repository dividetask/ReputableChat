# frozen_string_literal: true

require "json"

module ReputableChat
  module Crypto
    # Deterministic serialization for signed payloads: sorted keys, no whitespace,
    # UTF-8. Must produce byte-identical output to public/js/canonical.js or every
    # signature fails.
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
