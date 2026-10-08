# frozen_string_literal: true

require "bigdecimal"
require_relative "keys"
require_relative "record"

module Agnostic
  # The kinds of value section 1 of the rules defines, each as a predicate.
  module Formats
    DECIMAL = /\A-?(0|[1-9][0-9]*)(\.[0-9]{0,17}[1-9])?\z/
    FILE    = /\A[0-9a-f]{64}\.[a-z0-9]{1,5}\z/
    # Tab, newline and carriage return are the only control characters Text
    # may hold.
    CONTROL = /(?![\t\n\r])\p{Cc}/
    SURROUNDING_SPACE = /\A[[:space:]]|[[:space:]]\z/

    module_function

    # UTF-8, surrounding whitespace removed, no control characters but tab,
    # newline and carriage return, and a length in bytes.
    def text?(value, min: 0, max:)
      return false unless value.is_a?(String)

      value = value.dup.force_encoding(Encoding::UTF_8)
      value.valid_encoding? && !value.match?(SURROUNDING_SPACE) && !value.match?(CONTROL) &&
        value.bytesize.between?(min, max)
    end

    # "0.5", never ".5" or "0.50"; "0", never "-0".
    def decimal?(value) = value.is_a?(String) && value.match?(DECIMAL) && value != "-0"

    def decimal(value) = BigDecimal(value)

    # A BigDecimal in the one spelling a Decimal has.
    def write(value)
      text = value.to_s("F")
      text = text.sub(/0+\z/, "").sub(/\.\z/, "") if text.include?(".")
      text == "-0" ? "0" : text
    end

    def file?(value) = value.is_a?(String) && value.match?(FILE)

    def record_hash?(value) = Record.hash?(value)

    def signing_key?(value) = Keys.key?(value)

    alias encryption_key? signing_key?
    module_function :encryption_key?

    def timestamp?(value) = value.is_a?(Integer) && value >= 0

    # Sorted, with no duplicates: each element strictly greater than the last.
    def strictly_sorted?(values) = values.each_cons(2).all? { |a, b| a < b }

    def hash_list?(value, max:, min: 0)
      value.is_a?(Array) && value.size.between?(min, max) && value.all? { |h| record_hash?(h) } &&
        strictly_sorted?(value)
    end
  end
end
