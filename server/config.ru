# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "agnostic/server"

server = Agnostic::Server.new
# BACKGROUND=0 runs the API alone: no heartbeats, no syncing with peers.
server.start unless ENV["BACKGROUND"] == "0"

run server.app
