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
require_relative "rate_limit"
require_relative "rules"
require_relative "server_ratings"
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

    attr_reader :settings, :store, :rules, :ingest, :host, :heartbeat, :peers, :genesis, :ratings, :state

    def initialize(settings: Settings.load, clock: -> { Time.now.to_i }, http: nil)
      @settings = settings
      @clock = clock
      @genesis = load_genesis(settings.genesis_path)
      FileUtils.mkdir_p(settings.data_dir)
      @store = Store.new(settings.database_url)
      @rules = Rules.new(store: store, genesis: genesis)
      install_genesis
      @ingest = Ingest.new(store: store, rules: rules, settings: settings, clock: clock)
      @state = :catching_up
      @host = load_host
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
      server = self
      klass.state = -> { server.state }
      trusted = settings.trusted_proxies
      # Rack takes a caller's address from X-Forwarded-For only past proxies
      # this filter trusts. Out of the box it trusts any private address, so
      # anyone on the same network could claim to be anyone; here it trusts
      # only the proxies named.
      Rack::Request.ip_filter = ->(ip) { trusted.include?(ip) }
      klass.accounts = Accounts.new(store: store, genesis: genesis)
      klass.ratings = ratings
      klass.limiter = RateLimit.new(per_minute: settings.integer("limits", "sweep_requests_per_minute"), clock: @clock)
      klass.freeze.app
    end

    # Gets ready to serve: catches up and, after a split, waits for the
    # administrator's choice. config.ru calls this before Puma opens its port,
    # so a server not yet live is not listening at all.
    def prepare!
      catch_up
      wait_for_choice while state == :halted
      self
    end

    # Heartbeats at the configured interval, each followed at once by a sync
    # with every server, once the server is live.
    def start
      Thread.new do
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

    def live? = state == :live

    # Sweeps the chain from the servers given at setup, resuming where it
    # stopped, then looks for a chain split among their latest records.
    # Without one it goes live. With one it stops, and an administrator picks
    # the side to follow (`rake status`, then `rake "choose[<url>]"`). The
    # same happens on every start, so a server that wakes up after a long
    # time offline to find a split has its administrator settle it too.
    def catch_up
      return @state = :halted if halted

      urls = store.peers.select { |p| p[:source] == "settings" && !p[:forgotten] }.map { |p| p[:url] }
      peers.catch_up(urls)
      report = peers.check_splits(urls)
      return halt(report) unless report[:problems].empty?

      go_live(report[:tips].values.flatten)
    end

    # What a stop for a split recorded: the problems, each server's latest
    # records, and the pairs that split them.
    def halted = (json = store.meta("halted")) && !json.empty? ? JSON.parse(json) : nil

    def halt(report)
      store.save_meta("halted", JSON.generate("at" => @clock.call, "problems" => report[:problems],
                                              "tips" => report[:tips], "pairs" => report[:pairs]))
      warn "STOPPED: a chain split among the servers given at setup. Nothing is published or answered until " \
           "an administrator runs `rake status` and `rake \"choose[<url>]\"`.\n  #{report[:problems].join("\n  ")}"
      @state = :halted
    end

    # Which side of each splitting pair every server is on: :went_on when it
    # holds the heartbeat that orphaned the record, :left_behind when it holds
    # the record and not that heartbeat.
    def sides
      stop = halted or return {}
      stop["tips"].to_h do |url, tips|
        held = store.closure(tips)
        [url, stop["pairs"].map do |orphan, orphaner|
          if held.include?(orphaner) then :went_on
          elsif held.include?(orphan) then :left_behind
          end
        end]
      end
    end

    # The administrator's answer: follow the side the server at url is on.
    # Servers on the other side of any pair are forgotten.
    def choose(url)
      stop = halted or raise ArgumentError, "this server has not stopped for a split"
      all = sides
      chosen = all.fetch(url) { raise ArgumentError, "#{url} is not one of the servers that split" }
      all.each do |other, side|
        next if other == url

        opposite = side.zip(chosen).any? { |a, b| a && b && a != b }
        store.update_peer(other, forgotten: true) if opposite
      end
      store.save_meta("follow", JSON.generate(stop["tips"].fetch(url)))
      store.save_meta("halted", "")
    end

    # While stopped, waits for the administrator's choice, made by
    # `rake choose` in another process.
    def wait_for_choice
      sleep 5 while halted
      go_live(JSON.parse(store.meta("follow") || "[]"))
    end

    # Declares the host account, if it never has been, acknowledging where the
    # chain now is -- the latest records of the side it joins -- and publishes
    # a new declaration if the handle, bio or url have changed.
    def go_live(tips = [])
      submit_declaration(host.declare!(ack: anchor(tips), profile: profile, ts: @clock.call)) unless host.declared?
      redeclare(host)
      @state = :live
    end

    # At most 16 records to acknowledge, heartbeats first, newest first; the
    # genesis when there is nothing else.
    def anchor(tips)
      records = store.fetch_many(tips.uniq).select { |r| r.version == Rules::VERSION }
      chosen = records.sort_by { |r| [r.heartbeat? ? 0 : 1, -r.seq] }.first(Rules::ACK_RECORDS).map(&:digest)
      chosen.empty? ? [genesis.digest] : chosen
    end

    # Any change in what this server says of other servers is published just
    # before the heartbeat, so the heartbeat carries it to them.
    def beat_and_sync
      return unless live? && heartbeat.due?

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
      if settings.environment == "production" && !([record["pubkey"], record["mpubkey"]] & DEVELOPMENT_KEYS).empty?
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

    # The host account's phrases, made on first boot. Its declaration, if it
    # has one, goes back into the store in case the database is new.
    def load_host
      check_url
      host = HostAccount.load_or_create(dir: settings.host_dir, words: settings.integer("host", "seed_words"))
      submit_declaration(host.declaration) if host.declared?
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
