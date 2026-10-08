# frozen_string_literal: true

require "fileutils"
require "json"
require "monitor"
require_relative "host_account"
require_relative "app"
require_relative "heartbeat"
require_relative "ingest"
require_relative "peers"
require_relative "record"
require_relative "rules"
require_relative "settings"
require_relative "store"

module Agnostic
  # Everything wired together: the genesis, the store, the rules, this
  # server's host account, its heartbeats and its peers.
  class Server
    # The development genesis account's key. Public on purpose, so a production
    # server refuses to boot on any genesis it signed -- compared by key, since
    # the realistic mistake is copying the development record into place.
    DEVELOPMENT_KEY = "xK9fSKZEuhJvSCkdJoOeCQbM0wrBgFCsmhiwmNMf2hI"

    class BootError < StandardError; end

    attr_reader :settings, :store, :rules, :ingest, :host, :heartbeat, :peers, :genesis

    def initialize(settings: Settings.load, clock: -> { Time.now.to_i }, http: nil)
      @settings = settings
      @clock = clock
      @genesis = load_genesis(settings.genesis_path)
      FileUtils.mkdir_p(settings.data_dir)
      @store = Store.new(settings.database_url)
      @rules = Rules.new(store: store, genesis: genesis)
      install_genesis
      @ingest = Ingest.new(store: store, rules: rules, settings: settings, clock: clock)
      @host = declare_host
      @heartbeat = Heartbeat.new(store: store, ingest: ingest, host: host, settings: settings, clock: clock)
      @peers = Peers.new(store: store, ingest: ingest, settings: settings, http: http)
    end

    def app
      klass = Class.new(App)
      klass.store = store
      klass.ingest = ingest
      klass.host = host
      klass.genesis = genesis
      klass.settings = settings
      klass.freeze.app
    end

    # Heartbeats, pulling, pushing and expiring held records, each on its own
    # thread so a slow peer cannot delay a heartbeat.
    def start
      every(30) { heartbeat.beat }
      every(settings.integer("peers", "pull_interval_seconds")) { peers.pull_all }
      every(settings.integer("peers", "push_interval_seconds")) { peers.push_pending }
      every(300) { ingest.expire }
      self
    end

    private

    def every(seconds)
      Thread.new do
        loop do
          begin
            yield
          rescue StandardError => e
            warn "#{e.class}: #{e.message}"
          end
          sleep seconds
        end
      end
    end

    def load_genesis(path)
      raise BootError, "no genesis at #{path}: see server/README.md" unless File.exist?(path)

      record = Record.from_wire(JSON.parse(File.read(path)))
      if settings.environment == "production" && [record["pubkey"], record["mpubkey"]].include?(DEVELOPMENT_KEY)
        raise BootError, "#{path} is signed by the development genesis account, whose key is public"
      end

      record
    end

    def install_genesis
      verdict = rules.check(genesis)
      raise BootError, "the genesis is not valid: #{verdict.problems.join('; ')}" unless verdict.valid?

      store.insert(genesis) unless store.known?(genesis.digest)
    end

    def declare_host
      host = HostAccount.load_or_create(dir: settings.data_dir, genesis: genesis, handle: settings.handle,
                                       bio: settings.bio, clock: @clock)
      result = ingest.submit(host.declaration)
      return host if %i[accepted known].include?(result.status)

      raise BootError, "this server's host account declaration was refused: #{Array(result.problems).join('; ')}"
    end
  end
end
