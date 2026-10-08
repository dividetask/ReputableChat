# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "record"

module Agnostic
  # Exchanging records with other servers, once per heartbeat.
  #
  # Each time this server publishes a heartbeat it syncs with every peer:
  #
  # 1. Push: send every record accepted here since the last sync, except to
  #    the peer it came from. A peer that already has one answers "known".
  # 2. Offer the new heartbeat (POST /api/sync). The peer checks its ts
  #    against its own clock and ignores this server for good if the two are
  #    more than ten minutes apart -- a server whose clock is that far off is
  #    taken to be lying about time.
  # 3. The peer, checking the heartbeat, asks for every record in its
  #    history it does not hold, and is sent them, until it can check it.
  #    The ask travels as its answer rather than as a request of its own,
  #    because this server may have no address the peer can reach.
  #
  # Nothing is pulled from the peer: it shares its records the same way, when
  # it publishes its own heartbeat. pull_all remains, for catching up by hand.
  #
  # A peer whose host account this server ignores is skipped.
  #
  # Which servers: those named at setup or in the settings, and those learned
  # from records -- an account that publishes heartbeats and declares a url is
  # a server, and it is synced with once it answers at that url as that
  # account. A server that cannot be reached is tried less and less often,
  # and forgotten once it has gone peers.forget_after_seconds without being
  # reached; hearing from it again brings it back.
  class Peers
    def initialize(store:, ingest:, settings:, http: nil, clock: -> { Time.now.to_i }, host: nil)
      @clock = clock
      @store = store
      @ingest = ingest
      @settings = settings
      @host = host
      @http = http || method(:request)
      @outbox = Queue.new
      ingest.on_accept do |record, source|
        @outbox << [record, source]
        learn(record)
      end
    end

    attr_writer :host

    # The servers due a contact now.
    def urls
      now = @clock.call
      @store.peers.reject { |p| p[:forgotten] || p[:next_attempt_at] > now || own?(p) }.map { |p| p[:url] }
    end

    # Servers named in the settings or at setup. Ones already known keep
    # their state, so a forgotten one stays forgotten across restarts.
    def seed(urls) = urls.each { |url| @store.add_peer(url, source: "settings", at: @clock.call) unless @store.peer(url) }

    # --- learning about servers -------------------------------------------------

    # An account is a server once it has published a heartbeat; its url is the
    # one its latest identity declaration names.
    def learn(record)
      return unless %w[identity heartbeat].include?(record.kind)
      return if @host && record.account == @host.id

      account = record.account
      return unless record.heartbeat? || @store.by_account(account, kind: "heartbeat").any?

      declaration = record.kind == "identity" ? record : @store.by_account(account, kind: "identity").max_by(&:seq)
      url = declaration && Peers.url(declaration["url"])
      # The latest declaration is the account's address: one that names none,
      # or another, withdraws the addresses it named before.
      @store.withdraw_peers(account, except: url) if record.kind == "identity"
      # A new declaration brings a forgotten server back; its heartbeats alone
      # do not, or one that is unreachable at its url would be retried at full
      # pace for as long as its heartbeats travel through others.
      return unless url && room_for?(url)

      @store.add_peer(url, source: "learned", host: account, at: @clock.call, revive: record.kind == "identity")
    end

    # At most peers.max_learned learned servers are synced with. Past that, a
    # newly learned one is skipped; one already known stays.
    def room_for?(url)
      existing = @store.peer(url)
      return true if existing && !existing[:forgotten]

      @store.peers.count { |p| p[:source] == "learned" && !p[:forgotten] } < @settings.integer("peers", "max_learned")
    end

    def self.url(value)
      return unless value.is_a?(String)

      uri = URI.parse(value)
      %w[http https].include?(uri.scheme) && uri.host ? value.chomp("/") : nil
    rescue URI::InvalidURIError
      nil
    end

    # --- reachability -----------------------------------------------------------

    # Each failure waits longer before the next try: retry.first_seconds, times
    # retry.multiplier for each failure after the first, at most
    # retry.max_seconds.
    def retry_delay(failures)
      first = @settings.integer("peers", "retry", "first_seconds")
      factor = @settings.decimal("peers", "retry", "multiplier", minimum: 1)
      most = @settings.integer("peers", "retry", "max_seconds")
      [(first * (factor**(failures - 1))).to_i, most].min
    end

    def reached(url)
      @store.update_peer(url, failures: 0, next_attempt_at: 0, last_success_at: @clock.call)
      host = @store.peer_host(url)
      @store.record_contact(host, success: true, at: @clock.call) if host
    end

    def failed(url, reason)
      peer = @store.peer(url)
      return unless peer

      now = @clock.call
      failures = peer[:failures] + 1
      silent_since = peer[:last_success_at] || peer[:added_at]
      forget = now - silent_since >= @settings.integer("peers", "forget_after_seconds")
      @store.update_peer(url, failures: failures, next_attempt_at: now + retry_delay(failures), forgotten: forget)
      if peer[:host]
        @store.record_contact(peer[:host], success: false, at: now)
        @store.mark_offline(peer[:host]) if forget
      end
      warn "#{url}: #{reason}#{forget ? '; not reached in too long, so forgotten' : ''}"
    end

    # --- pull -------------------------------------------------------------------

    def pull_all
      urls.each do |url|
        next unless contact(url)

        pull(url, raise_errors: true)
        reached(url)
      rescue StandardError => e
        failed(url, "pull failed: #{e.message}")
      end
    end

    def pull(url, raise_errors: false)
      page = @settings.integer("limits", "page_records")
      budget = @settings.integer("peers", "fetch_missing")
      loop do
        cursor = @store.peer_cursor(url)
        body = get(url, "/api/records?since=#{cursor}&limit=#{page}")
        records = Array(body["records"])
        records.each do |wire|
          result = @ingest.submit(Record.from_wire(wire), source: url)
          budget = fetch_missing(url, result.missing, budget) if result.status == :pending
        end
        @store.save_peer_cursor(url, body["next"]) if body["next"].to_i > cursor
        break if records.size < page
      end
    rescue StandardError => e
      raise if raise_errors

      warn "pull from #{url} failed: #{e.message}"
    end

    # Fetches what a held record is waiting for, and what that is waiting for,
    # within a budget so a peer cannot keep this server fetching forever.
    def fetch_missing(url, missing, budget)
      queue = Array(missing).dup
      while (hash = queue.shift) && budget.positive?
        next if @store.known?(hash) || @store.pending?(hash) || !Record.hash?(hash)

        budget -= 1
        wire = get(url, "/api/records/#{hash}")
        result = @ingest.submit(Record.from_wire(wire), source: url)
        queue.concat(Array(result.missing)) if result.status == :pending
      end
      budget
    end

    # --- sync ------------------------------------------------------------------

    # Called with each heartbeat this server publishes.
    def sync(beat)
      batch = []
      batch << @outbox.pop until @outbox.empty?
      batch.reject! { |record, _| record.digest == beat.digest }

      urls.each do |url|
        next unless contact(url)

        push(url, batch.reject { |_, source| source == url }.map(&:first))
        body = post(url, "/api/sync", { "heartbeat" => beat.to_wire })
        push_missing(url, body)
        reached(url)
      rescue StandardError => e
        failed(url, "sync failed: #{e.message}")
      end
    end

    # Asks the server at url who it is. A peer is known by its host account,
    # which is what gets ignored; a learned one must answer as the account
    # whose declaration named the url. False when it is not to be synced
    # with, a failure when it could not be reached.
    def contact(url)
      host = get(url, "/api")["host"]
      known = @store.peer_host(url)
      if known && host != known
        failed(url, "answers as #{host}, not as #{known}, whose declaration named it")
        return false
      end

      @store.save_peer_host(url, host) if Record.hash?(host)
      return false if @host && host == @host.id

      !(host && @store.ignored?(host, at: @clock.call))
    rescue StandardError => e
      failed(url, "unreachable: #{e.message}")
      false
    end

    def own?(peer) = @host && peer[:host] == @host.id

    def push(url, records)
      records.each_slice(@settings.integer("limits", "batch_records")) do |slice|
        push_missing(url, post(url, "/api/records", { "records" => slice.map(&:to_wire) }))
      end
    end

    # Sends whatever the peer says it is still missing that this server holds
    # -- the mirror of fetch_missing, within the same kind of budget.
    def push_missing(url, body)
      budget = @settings.integer("peers", "fetch_missing")
      loop do
        wanted = Array(body["results"]).flat_map { |r| Array(r["missing"]) }.uniq.first(budget)
        records = @store.fetch_many(wanted.select { |h| Record.hash?(h) })
        break if records.empty?

        budget -= records.size
        body = post(url, "/api/records", { "records" => records.map(&:to_wire) })
      end
    end

    def outbox_size = @outbox.size

    private

    def get(url, path) = @http.call(:get, url + path, nil)

    def post(url, path, body) = @http.call(:post, url + path, body)

    def request(method, address, body)
      uri = URI(address)
      timeout = @settings.integer("peers", "timeout_seconds")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: timeout, read_timeout: timeout) do |http|
        request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end
        response = http.request(request)
        raise "#{method.upcase} #{address} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    end
  end
end
