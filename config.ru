# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "reputable_chat/app"
require "reputable_chat/server_config"

settings = ReputableChat::ServerConfig.load

ReputableChat::App.store  = ReputableChat::Store::Database.new(settings.fetch("database_url"))
ReputableChat::App.images = ReputableChat::Store::Images.new(settings.fetch("image_root"))
ReputableChat::App.origin = settings.fetch("origin")

run ReputableChat::App.freeze.app
