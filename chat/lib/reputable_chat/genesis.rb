# frozen_string_literal: true

require_relative "committed_declaration"

module ReputableChat
  # The bottom of the chain: the genesis account's identity declaration.
  #
  # The genesis account is the developer's. It is the same on every server,
  # because there is one network and one chain; each server's own account is
  # the host account (see host.rb), which acknowledges this record.
  #
  # Every record that has seen nothing else acknowledges this one, and it is the
  # only record whose own `ack` is null. It is stored as a file rather than
  # regenerated from a database row, because every client has to agree on the
  # hash before it has fetched anything -- a genesis you have to download from
  # the server is not a genesis.
  #
  # Generated once by script/generate_genesis.rb and committed.
  #
  # There are two of them, because a developer needs to be able to sign as the
  # genesis account and a production network needs nobody else to be able to.
  # Development's seed is committed and therefore public: anyone who has cloned
  # the repository owns that identity, which is exactly what makes a fresh
  # clone useful. Production's seed is never committed.
  class Genesis
    include CommittedDeclaration

    DIRECTORY = File.expand_path("../../config/genesis", __dir__)

    class Missing < StandardError; end
    class Corrupt < StandardError; end
    class WrongEnvironment < StandardError; end

    PATH = path(Environment::DEVELOPMENT)

    def self.label = "genesis"

    def self.load(path: self.path) = new(read_record(path), path: path)

    # Memoized, since it never changes while a process is running.
    def self.current = @current ||= refuse_development_in_production(load)

    def self.reset! = @current = nil

    def self.development_message
      "this is the development genesis, whose seed is committed to the repository and " \
        "therefore public. Generate a production one with " \
        "`RACK_ENV=production bundle exec rake genesis` and keep its seed out of git."
    end

    def self.missing_message(path)
      "no genesis record at #{path}. Generate one with " \
        "`#{Environment.production? ? 'RACK_ENV=production ' : ''}bundle exec rake genesis` " \
        "and commit it -- nothing can be acknowledged until it exists."
    end

    def initialize(record, path: Genesis.path) = adopt(record, path)

    private

    # The one record that acknowledges nothing, because there was nothing to
    # acknowledge.
    def check_ack!(path)
      return if declaration["ack"].nil?

      raise Corrupt, "#{path} acknowledges #{declaration['ack']}, but the genesis is the bottom " \
                     "of the chain and acknowledges nothing"
    end
  end
end
