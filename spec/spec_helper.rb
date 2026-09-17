# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "bigdecimal"
require "reputable_chat/config"
require "reputable_chat/reputation/engine"
require "reputable_chat/store/memory"

module SpecHelper
  def config(overrides = {})
    ReputableChat::Config.load(overrides: overrides)
  end

  def engine(store, overrides = {})
    ReputableChat::Reputation::Engine.new(config: config(overrides), store: store)
  end

  def store = ReputableChat::Store::Memory.new
  def dec(str) = BigDecimal(str.to_s)
end
