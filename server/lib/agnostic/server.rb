# frozen_string_literal: true

require "fileutils"
require "json"
require "monitor"
require "uri"
require_relative "formats"
require_relative "host_account"
require_relative "app"
require_relative "heartbeat"
require_relative "ingest"
require_relative "peers"
require_relative "record"
require_relative "rate_limit"
require_relative "rules"
require_relative "server_ratings"
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

    attr_reader :settings, :store, :rules, :ingest, :host, :heartbeat, :peers, :genesis, :ratings

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
      @peers = Peers.new(store: store, ingest: ingest, settings: settings, http: http, clock: clock, host: host)
      peers.seed(settings.peers)
      assign_missed_generations
      @ratings = ServerRatings.new(store: store, ingest: ingest, host: host, settings: settings, clock: clock)
    end

    def app
      klass = Class.new(App)
      klass.store = store
      klass.ingest = ingest
      klass.host = host
      klass.genesis = genesis
      klass.settings = settings
      klass.clock = @clock
      klass.limiter = RateLimit.new(per_minute: settings.integer("limits", "sweep_requests_per_minute"), clock: @clock)
      klass.freeze.app
    end

    # Heartbeats at the configured interval, each followed at once by a sync
    # with every server. The timer thread waits between them and this server
    # contacts no one meanwhile; the API stays up throughout, for any server
    # that wants to reach this one.
    def start
      Thread.new do
        catch_up
        loop do
          begin
            beat_and_sync
          rescue StandardError => e
            warn "#{e.class}: #{e.message}"
          end
          sleep [heartbeat.seconds_until_due, 1].max
        end
      end
      every(settings.integer("pending", "sweep_seconds")) { ingest.expire }
      self
    end

    # Before going live -- before its first heartbeat after a restart, too --
    # a server sweeps the chain from the servers it was given at setup,
    # resuming where it stopped.
    def catch_up
      peers.catch_up(store.peers.select { |p| p[:source] == "settings" && !p[:forgotten] }.map { |p| p[:url] })
    rescue StandardError => e
      warn "catching up failed: #{e.message}"
    end

    # Any change in what this server says of other servers is published just
    # before the heartbeat, so the heartbeat carries it to them.
    def beat_and_sync
      return unless heartbeat.due?

      ratings.publish
      result = heartbeat.beat
      return result unless result&.status == :accepted

      peers.sync(heartbeat.previous)
      result
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

    # Heartbeats stored before generations were kept, oldest first.
    def assign_missed_generations
      store.db[:records].where(kind: "heartbeat").order(:seq).all.each do |row|
        beat = store.fetch(row[:hash])
        store.assign_generations(beat) unless store.generations_assigned?(beat)
      end
    end

    def install_genesis
      verdict = rules.check(genesis)
      raise BootError, "the genesis is not valid: #{verdict.problems.join('; ')}" unless verdict.valid?

      store.insert(genesis) unless store.known?(genesis.digest)
    end

    def declare_host
      check_url
      host = HostAccount.load_or_create(dir: settings.data_dir, genesis: genesis, profile: profile,
                                       words: settings.integer("host", "seed_words"), clock: @clock)
      submit_declaration(host.declaration)
      redeclare(host)
      host
    end

    # What the host account's identity declaration says, from the settings.
    def profile = { "title" => settings.handle, "body" => settings.bio, "url" => settings.url }.compact

    # A later declaration replaces the account's previous one (section 3), so
    # a changed handle, bio or url is published as a new one.
    def redeclare(host)
      current = store.by_account(host.id, kind: "identity").max_by(&:seq)
      return if %w[title body url].all? { |k| current[k] == profile[k] }

      latest = store.by_account(host.id).max_by(&:seq)
      submit_declaration(host.sign("identity", profile.merge("ack" => [latest.digest], "ts" => @clock.call)))
    end

    def submit_declaration(record)
      result = ingest.submit(record)
      return if %i[accepted known].include?(result.status)

      raise BootError, "this server's host account declaration was refused: #{Array(result.problems).join('; ')}"
    end

    def check_url
      url = settings.url
      return if url.nil?

      uri = URI.parse(url)
      return if %w[http https].include?(uri.scheme) && uri.host && Formats.text?(url, min: 1, max: 2_048) &&
                !url.match?(/[[:space:]]/)

      raise BootError, "host.url #{url.inspect} is not an http or https address"
    rescue URI::InvalidURIError
      raise BootError, "host.url #{url.inspect} is not an http or https address"
    end
  end
end
