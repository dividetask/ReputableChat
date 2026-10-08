# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "record"

module Agnostic
  # Exchanging records with other servers, both ways.
  #
  # Pull: ask each peer for what it accepted since the last time, in the order
  # it accepted them, which puts every record after what it acknowledges. A
  # record that still arrives ahead of an ancestor -- the peer was holding it,
  # or accepted the ancestor before this server's cursor -- is held, and the
  # missing ancestors fetched from that peer by hash.
  #
  # Push: send each record accepted here to every peer but the one it came
  # from. A peer that already has it answers "known", so pushing and pulling
  # the same record costs a request and nothing else.
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

    def pull_all = urls.each { |url| pull(url) }

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

    # --- push -------------------------------------------------------------------

    def push_pending
      batch = []
      batch << @outbox.pop until @outbox.empty? || batch.size >= @settings.integer("limits", "batch_records")
      return if batch.empty?

      urls.each do |url|
        records = batch.reject { |_, source| source == url }.map(&:first)
        push(url, records) unless records.empty?
      rescue StandardError => e
        warn "push to #{url} failed: #{e.message}"
      end
    end

    # Sends records, then whatever the peer says it is still missing for them
    # that this server holds -- the mirror of fetch_missing, within the same
    # kind of budget.
    def push(url, records)
      budget = @settings.integer("peers", "fetch_missing")
      until records.empty?
        body = post(url, "/api/records", { "records" => records.map(&:to_wire) })
        wanted = Array(body["results"]).flat_map { |r| Array(r["missing"]) }.uniq.first(budget)
        budget -= wanted.size
        records = @store.fetch_many(wanted.select { |h| Record.hash?(h) })
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
