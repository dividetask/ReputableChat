# frozen_string_literal: true

require "bigdecimal"

module ReputableChat
  module Reputation
    # The three decimals the rating rules are written in terms of. Defined once
    # here because a Struct.new block defines its constants on the enclosing
    # module, so two structs each declaring them is a redefinition warning and
    # a question about which one won.
    ZERO     = BigDecimal("0")
    ONE      = BigDecimal("1")
    NEGATIVE = BigDecimal("-1")

    module_function

    # The form a score travels in, and the one `toDecimal` in
    # public/js/reputation.js produces. Both write scores into signed records,
    # so they agree on the text rather than merely on the number: "1.0" and "1"
    # parse the same on both sides today, and the first thing to compare two
    # published scores as strings would find they do not.
    #
    # Never exponent notation. Canonical serialization refuses a float outright
    # because it has no single textual form across languages, and a reader
    # parsing "5e-2" where it expected "0.05" gets a different number.
    def decimal(value, scale)
      sign, digits, _, exponent = value.round(scale).split
      return "0" if digits.to_i.zero?

      whole = exponent.positive? ? digits[0, exponent].to_s.ljust(exponent, "0") : "0"
      fraction = (exponent.positive? ? digits[exponent..] : "0" * -exponent + digits).to_s
      fraction = fraction.sub(/0+\z/, "")

      "#{'-' if sign.negative?}#{whole}#{".#{fraction}" unless fraction.empty?}"
    end
  end
end
