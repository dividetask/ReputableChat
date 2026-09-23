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
  end
end
