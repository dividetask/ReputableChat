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
      attr_accessor :store, :ingest, :host, :genesis, :settings, :clock
    end

    error do |e|
      response.status = 500
      warn "#{e.class}: #{e.message}"
      { "error" => "internal error" }
    end

    route do |r|
      r.on "api" do
        r.is { r.get { overview } }
        r.get("genesis") { server.genesis.to_wire }
        r.get("host") { server.host.to_h }
        r.get("frontier") { { "records" => store.frontier.map(&:digest) } }

        r.post("sync") { sync(r) }

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
      r.halt(403, { "error" => "this server ignores #{author}" }) if store.ignored?(author)

      skew = record.ts - server.clock.call
      allowed = server.settings.integer("peers", "max_clock_skew_seconds")
      if skew.abs > allowed
        verdict = server.ingest.rules.check(record)
        unless verdict.valid?
          r.halt(422, { "error" => "the heartbeat's ts is #{skew} seconds from this server's clock, " \
                                   "and it could not be shown to be #{author}'s" })
        end

        reason = "its heartbeat #{record.digest} was #{skew} seconds from this server's clock, over the #{allowed} allowed"
        store.ignore(author, reason: reason, at: server.clock.call)
        r.halt(403, { "error" => "this server now ignores #{author}: #{reason}" })
      end

      result = server.ingest.submit(record).to_h
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
