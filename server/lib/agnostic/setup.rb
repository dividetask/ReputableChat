# frozen_string_literal: true

require "fileutils"
require "yaml"
require_relative "peers"
require_relative "settings"

module Agnostic
  # `rake setup`: the questions a fresh server is asked, answered into
  # data/<environment>/settings.yml, which sits over config/server.yml and is
  # never committed.
  #
  # The list of other servers may be empty. The server then runs as the only
  # one it knows of until another reaches it, and learns of the rest from the
  # records passed along.
  class Setup
    def initialize(settings:, input: $stdin, output: $stdout)
      @settings = settings
      @in = input
      @out = output
    end

    def run
      handle = ask("This server's handle", @settings.handle)
      url = ask_url
      peers = ask_peers
      write("host" => { "handle" => handle, "url" => url }.compact, "peers" => { "urls" => peers })
      @out.puts(peers.empty? ? "No other servers: this one will run alone until another reaches it." :
                               "Will sync with #{peers.size} server#{'s' unless peers.size == 1} after each heartbeat.")
      path
    end

    def path = File.join(@settings.data_dir, Settings::LOCAL)

    private

    def ask(question, default)
      @out.print("#{question}#{" [#{default}]" if default && !default.empty?}: ")
      answer = @in.gets.to_s.strip
      answer.empty? ? default : answer
    end

    def ask_url
      @out.puts("The address other servers reach this one at, such as https://chain.example.org.")
      @out.puts("Leave it blank if they cannot reach it; it will still reach them.")
      loop do
        answer = ask("Address", @settings.url)
        return nil if answer.nil? || answer.empty?
        return Peers.url(answer) if Peers.url(answer)

        @out.puts("  #{answer} is not an http or https address.")
      end
    end

    def ask_peers
      @out.puts("Other servers to sync with, one address per line; a blank line to finish.")
      @out.puts("None at all means this server is the only one it knows of.")
      peers = []
      while (line = @in.gets) && !line.strip.empty?
        url = Peers.url(line.strip)
        url ? peers << url : @out.puts("  #{line.strip} is not an http or https address; skipped.")
      end
      peers.uniq
    end

    def write(values)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# Written by `rake setup`; config/server.yml holds the rest.\n#{YAML.dump(values)}")
    end
  end
end
