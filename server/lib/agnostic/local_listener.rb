# frozen_string_literal: true

require "fileutils"
require "socket"

module Agnostic
  # The listener only the apps beside this server can reach: a Unix socket in
  # the host account's directory, 0600, so only processes of the user the
  # server runs as can connect -- the same ones that can read the host
  # account's phrase. On it uploads need no signature, and the apps make the
  # requests only they may make (POST /api/adjustments).
  #
  # It is its own Puma server, started by the agnostic server once it is live,
  # so it is there however Puma's public listener was bound (`-b` or `-p` on
  # the command line replaces the binds a config file names).
  #
  # Which listener a request came in on is read from the connection itself,
  # the socket Puma accepted it on, never from anything the request says:
  # Host, X-Forwarded-* and SERVER_PORT are all the client's to choose.
  class LocalListener
    # Whether the request in env came in on the socket at path.
    def self.local?(env, path)
      socket = env["puma.socket"]
      return false unless path && socket.is_a?(UNIXSocket)

      socket.local_address.unix_path == path
    rescue SystemCallError, IOError, SocketError
      false
    end

    attr_reader :path

    def initialize(app, path)
      @app = app
      @path = path
    end

    def start
      require "puma"
      require "puma/server"
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      @server = Puma::Server.new(@app, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
      @server.add_unix_listener(path, 0o177) # umask: the socket is 0600
      @server.run
      self
    end

    def stop
      @server&.stop(true)
      FileUtils.rm_f(path)
    end
  end
end
