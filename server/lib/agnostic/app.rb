# frozen_string_literal: true

require "json"
require "roda"
require_relative "record"
require_relative "rules"

module Agnostic
  # The API other servers, and the apps built on the chain, talk to. It knows
  # records and nothing about what any app does with them.
  #
  #   GET  /api                      what this server is: genesis, host account, rules version
  #   GET  /api/genesis              the genesis record
  #   GET  /api/host                 this server's host account and its declaration
  #   GET  /api/records              records accepted after ?since=<cursor>, oldest first
  #   GET  /api/records/<hash>       one record
  #   GET  /api/frontier             records nothing here acknowledges yet
  #   POST /api/records              {"records": [...]} or one record; each is checked
  #   GET  /api/sweep                ?account=&generation=&part=: the chain in parts, for catching up
  #   POST /api/sync                 {"heartbeat": ...}: a peer's newest heartbeat, its clock checked
  class App < Roda
    plugin :json, classes: [Array, Hash]
    plugin :json_parser, content_type_regexp: %r{\Aapplication/json\b}i,
                         error_handler: ->(r) { r.halt([400, { "content-type" => "application/json" }, [JSON.generate("error" => "body is not JSON")]]) }
    plugin :all_verbs
    plugin :halt
    plugin :error_handler

    # Each server gets its own subclass carrying its parts, so two servers can
    # run in one process -- as they do in the peer specs.
    class << self
      attr_accessor :store, :ingest, :host, :genesis, :settings, :clock, :limiter, :state
    end

    error do |e|
      response.status = 500
      warn "#{e.class}: #{e.message}"
      { "error" => "internal error" }
    end

    route do |r|
      # Not live -- still catching up, or stopped for a chain split -- means
      # answering no one: this server has nothing it should vouch for yet.
      case server.state&.call
      when :catching_up then r.halt(503, { "error" => "this server is catching up with the chain" })
      when :halted then r.halt(503, { "error" => "this server has stopped for a chain split" })
      end

      r.on "api" do
        r.is { r.get { overview } }
        r.get("genesis") { server.genesis.to_wire }
        r.get("host") { server.host.to_h }
        r.get("frontier") { { "records" => store.frontier.map(&:digest) } }

        r.post("sync") { sync(r) }
        r.get("sweep") { sweep(r) }

        r.on "records" do
          r.is do
            r.get { page(r) }
            r.post { post(r) }
          end
          r.get(String) do |hash|
            record = Record.hash?(hash) && store.fetch(hash)
            record ? record.to_wire : r.halt(404, { "error" => "no record #{hash[0, 64]} here" })
          end
        end
      end
    end

    private

    def server = self.class

    def store = server.store

    def limit(name) = server.settings.integer("limits", name)

    def overview
      {
        "rules" => Rules::VERSION, "genesis" => server.genesis.digest, "host" => server.host.id,
        "url" => server.settings.url,
        "records" => store.count, "cursor" => store.last_seq,
        "heartbeat_interval_seconds" => server.settings.integer("heartbeat", "interval_seconds"),
        "limits" => %w[request_bytes batch_records page_records].to_h { |k| [k, limit(k)] }
      }
    end

    # The cursor is this server's own count, opaque to anybody else: pass the
    # "next" from one page as "since" for the one after.
    def page(r)
      since = Integer(r.params["since"].to_s, exception: false) || 0
      wanted = Integer(r.params["limit"].to_s, exception: false)
      size = wanted&.positive? ? [wanted, limit("page_records")].min : limit("page_records")
      filters = %w[type account target].to_h { |k| [k.to_sym, r.params[k]] }.reject { |_, v| v.to_s.empty? }
      records = store.since(since, limit: size, **filters)
      { "records" => records.map(&:to_wire), "next" => records.last&.seq || since }
    end

    # A full sweep, for a server catching up: one part of one generation of
    # an account that publishes heartbeats (store.rb says what a generation
    # is), this server's own unless ?account= names another. A part holds at
    # most limits.sweep_records, each record after everything it acknowledges
    # and in the same order on every server; the part size is this server's
    # own, so a caller takes every part of a generation from the same server.
    # "next" names the part after this
    # one, or the next generation's first, and is null once this server has
    # no later generation of that account. Each caller may ask
    # limits.sweep_requests_per_minute times a minute.
    def sweep(r)
      wait = server.limiter.wait(r.ip)
      if wait
        response["retry-after"] = wait.to_s
        r.halt(429, { "error" => "too many sweep requests; ask again in #{wait} seconds" })
      end

      account = r.params["account"].to_s.empty? ? server.host.id : r.params["account"].to_s
      r.halt(400, { "error" => "account must be an account ID" }) unless Record.hash?(account)
      generation = [Integer(r.params["generation"].to_s, exception: false) || 1, 1].max
      part = [Integer(r.params["part"].to_s, exception: false) || 0, 0].max
      size = limit("sweep_records")
      latest = store.latest_generation(account)
      count = generation <= latest ? store.generation_size(account, generation) : 0
      parts = (count + size - 1) / size
      records = part < parts ? store.generation_part(account, generation, part, size) : []
      following = if part + 1 < parts then { "generation" => generation, "part" => part + 1 }
                  elsif generation < latest then { "generation" => generation + 1, "part" => 0 }
                  end
      { "account" => account, "generation" => generation, "part" => part, "parts" => parts, "latest" => latest,
        "records" => records.map(&:to_wire), "next" => following }
    end

    # A peer offering the heartbeat it has just published. Its ts says what the
    # peer's clock read a moment ago, so a ts more than the allowed skew from
    # this server's clock means the peer's clock is wrong or it is lying about
    # time, and this server ignores it from then on. Only once the heartbeat
    # is shown to be signed by the account it names: otherwise anyone could
    # get an honest server ignored with a forged one.
    def sync(r)
      body = r.POST
      record = Record.from_wire(body.is_a?(Hash) ? body["heartbeat"] : nil)
      r.halt(400, { "error" => "heartbeat must be a heartbeat record" }) unless heartbeat?(record)

      author = record.account
      now = server.clock.call
      r.halt(403, { "error" => "this server ignores #{author}" }) if store.ignored?(author, at: now)

      skew = record.ts - now
      allowed = server.settings.integer("peers", "max_clock_skew_seconds")
      if skew.abs > allowed
        verdict = server.ingest.rules.check(record)
        unless verdict.valid?
          r.halt(422, { "error" => "the heartbeat's ts is #{skew} seconds from this server's clock, " \
                                   "and it could not be shown to be #{author}'s" })
        end

        reason = "its heartbeat #{record.digest} was #{skew} seconds from this server's clock, over the #{allowed} allowed"
        period = server.settings.integer("peers", "ignore_seconds")
        store.ignore(author, reason: reason, at: now, until_at: now + period)
        r.halt(403, { "error" => "this server ignores #{author} until #{Time.at(now + period).utc}: #{reason}" })
      end

      result = server.ingest.submit(record).to_h
      # It just reached this server, so it is not offline, whatever this
      # server's own attempts to reach it say.
      store.peer_alive(author, at: now) unless result["status"] == "refused"
      response.status = 202 if result["status"] == "pending"
      { "results" => [result] }
    rescue ArgumentError, Canonical::NotCanonical
      r.halt(400, { "error" => "heartbeat must be a heartbeat record" })
    end

    def heartbeat?(record)
      record.digest && record.heartbeat? && record.ts.is_a?(Integer) && Record.hash?(record.account)
    end

    def post(r)
      if (r.env["CONTENT_LENGTH"].to_i) > limit("request_bytes")
        r.halt(413, { "error" => "request over #{limit('request_bytes')} bytes" })
      end

      body = r.POST
      wires = body.is_a?(Hash) && body.key?("records") ? body["records"] : [body]
      r.halt(400, { "error" => "records must be a list" }) unless wires.is_a?(Array)
      r.halt(413, { "error" => "over #{limit('batch_records')} records in one request" }) if wires.size > limit("batch_records")

      results = wires.map do |wire|
        server.ingest.submit(Record.from_wire(wire)).to_h
      rescue ArgumentError => e
        { "status" => "refused", "problems" => [e.message] }
      end
      response.status = 202 if results.any? { |x| x["status"] == "pending" }
      { "results" => results }
    end
  end
end
