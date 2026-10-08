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
  # 3. Send whatever the peer answers it is still missing.
  # 4. Pull: ask the peer for what it accepted since the last time, in the
  #    order it accepted them, which puts every record after what it
  #    acknowledges. A record that arrives ahead of an ancestor is held, and
  #    the missing ancestors fetched from that peer by hash.
  #
  # A peer whose host account this server ignores is skipped.
  class Peers
    def initialize(store:, ingest:, settings:, http: nil)
      @store = store
      @ingest = ingest
      @settings = settings
      @http = http || method(:request)
      @outbox = Queue.new
      ingest.on_accept { |record, source| @outbox << [record, source] }
    end

    def urls = @settings.peers

    # --- pull -------------------------------------------------------------------

    def pull_all = urls.each { |url| pull(url) unless ignored_peer?(url) }

    def pull(url)
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
        next if ignored_peer?(url)

        push(url, batch.reject { |_, source| source == url }.map(&:first))
        body = post(url, "/api/sync", { "heartbeat" => beat.to_wire })
        push_missing(url, body)
        pull(url)
      rescue StandardError => e
        warn "sync with #{url} failed: #{e.message}"
      end
    end

    # A peer is known by the host account it reports; the account, not the
    # address, is what gets ignored.
    def ignored_peer?(url)
      host = get(url, "/api")["host"]
      @store.save_peer_host(url, host) if Record.hash?(host)
      host && @store.ignored?(host)
    end

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
