# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "agnostic/server"

# Catching up -- and, after a chain split, waiting for an administrator to
# pick a side -- happens here, before Puma binds its port: Puma loads this
# file first and listens after. A server not yet live is not listening, so
# nobody can reach it. (In cluster mode this holds only with preload_app!.)
server = Agnostic::Server.new.prepare!
# BACKGROUND=0 runs the API alone: no heartbeats, no syncing with peers.
server.start unless ENV["BACKGROUND"] == "0"

run server.app
