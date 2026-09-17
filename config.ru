# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "reputable_chat/app"

ReputableChat::App.store  = ReputableChat::Store::Database.new(
  ENV.fetch("DATABASE_URL", "sqlite://data/reputablechat.db")
)
ReputableChat::App.origin = ENV.fetch("ORIGIN", "http://localhost:9292")

run ReputableChat::App.freeze.app
