# frozen_string_literal: true

require "fileutils"
require "json"
require "monitor"
require "uri"
require_relative "formats"
require_relative "host_account"
require_relative "app"
require_relative "accounts"
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
    # The development genesis account's keys, working and master. Public on
    # purpose, so a production server refuses to boot on any genesis they signed
    # or declare -- compared by key, since
    # the realistic mistake is copying the development record into place.
    DEVELOPMENT_KEYS = [
      "DRaBa2gChkx35qTlH8xqTG96uOX_T8TEDmuGQqy6Ndk", # working key
      "qSJtJXOef6yQPcp5T6-aa4INc5qmdBdpuAyGOgHyxVo"  # master key
    ].freeze

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
      @peers = Peers.new(store: store, ingest: ingest, settings: settings, http: http, clock: clock)
    end

    def app
      klass = Class.new(App)
      klass.store = store
      klass.ingest = ingest
      klass.host = host
      klass.genesis = genesis
      klass.settings = settings
      klass.clock = @clock
      klass.accounts = Accounts.new(store: store, genesis: genesis)
      klass.freeze.app
    end

    # Each heartbeat is followed by a sync with every peer.
    def start
      every(30) { beat_and_sync }
      every(300) { ingest.expire }
      self
    end

    def beat_and_sync
      result = heartbeat.beat
      peers.sync(heartbeat.previous) if result&.status == :accepted
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
      if settings.environment == "production" && !([record["pubkey"], record["mpubkey"]] & DEVELOPMENT_KEYS).empty?
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
      check_url
      host = HostAccount.load_or_create(dir: settings.data_dir, genesis: genesis, profile: profile, clock: @clock)
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
