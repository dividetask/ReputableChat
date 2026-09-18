# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "reputable_chat/app"
require "reputable_chat/server_config"
require "reputable_chat/genesis"

settings = ReputableChat::ServerConfig.load

ReputableChat::App.store  = ReputableChat::Store::Database.new(settings.fetch("database_url"))
ReputableChat::App.images = ReputableChat::Store::Images.new(settings.fetch("image_root"))
ReputableChat::App.origin = settings.fetch("origin")
# Loaded at boot, and verified as it loads: a genesis that has been edited or
# truncated would otherwise put every client on a slightly different chain and
# show up only as signatures failing for no visible reason.
ReputableChat::App.genesis = ReputableChat::Genesis.current

run ReputableChat::App.freeze.app
