# frozen_string_literal: true

require_relative "committed_declaration"
require_relative "genesis"

module ReputableChat
  # The host account: this server's own account, and optional.
  #
  # The genesis account is the developer's and the same everywhere. A server
  # that wants a voice of its own -- to announce an outage, to vouch for the
  # people who join through it -- generates a host account. Its first identity
  # declaration acknowledges the genesis record, so the server's account hangs
  # off the one chain rather than starting a second.
  #
  # A new account starts with both as friends, or with the genesis account
  # alone where the server has no host account. Either is an ordinary friend
  # the person can remove.
  #
  # Committed as a file for the same reason the genesis is: a client needs it
  # before it has fetched anything. Development's seed is committed and public,
  # like the development genesis; every other environment's is gitignored.
  class Host
    include CommittedDeclaration

    DIRECTORY = File.expand_path("../../config/host", __dir__)

    class Missing < StandardError; end
    class Corrupt < StandardError; end
    class WrongEnvironment < StandardError; end

    def self.label = "host account"

    def self.load(path: self.path, genesis: Genesis.current)
      new(read_record(path), path: path, genesis: genesis)
    end

    # nil when this server has none -- having one is a choice, not a
    # requirement. Memoized, since it never changes while a process is running.
    def self.current
      return @current if defined?(@current)

      @current = File.exist?(path) ? refuse_development_in_production(load) : nil
    end

    def self.reset!
      remove_instance_variable(:@current) if defined?(@current)
    end

    def self.development_message
      "this is the development host account, whose seed is committed to the repository and " \
        "therefore public. Generate a production one with " \
        "`RACK_ENV=production bundle exec rake host`, or delete config/host/production.json " \
        "to run without one."
    end

    def self.missing_message(path)
      "no host account at #{path}. Generate one with " \
        "`#{Environment.production? ? 'RACK_ENV=production ' : ''}bundle exec rake host`."
    end

    def initialize(record, genesis:, path: Host.path)
      @genesis = genesis
      adopt(record, path)
    end

    private

    # A host account that does not acknowledge the genesis is on another chain,
    # and every record its server's people make would hang off it rather than
    # off the network's.
    def check_ack!(path)
      return if declaration["ack"] == @genesis.hash

      raise Corrupt, "#{path} acknowledges #{declaration['ack'].inspect}, not the genesis " \
                     "#{@genesis.hash}. A host account is generated against the genesis " \
                     "it will serve."
    end
  end
end
