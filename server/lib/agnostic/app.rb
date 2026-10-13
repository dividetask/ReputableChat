# frozen_string_literal: true

require "json"
require "roda"
require_relative "record"
require_relative "rules"
require_relative "accounts"
require_relative "formats"
require_relative "local_listener"
require_relative "upload_auth"

module Agnostic
  # The API other servers, and the apps built on the chain, talk to. It knows
  # records and nothing about what any app does with them.
  #
  #   GET  /api                      what this server is: genesis, host account, rules version
  #   GET  /api/genesis              the genesis record
  #   GET  /api/host                 this server's host account and its declaration
  #   GET  /api/records              records accepted after ?since=<cursor>, oldest first
  #   GET  /api/records/<hash>       one record, with its state
  #   POST /api/states               {"hashes": [...]}: each record's state as this server sees it
  #   GET  /api/accounts/<id>        an account's newest declaration and attestation, and latest record
  #   POST /api/accounts             {"accounts": [...]}: the same for several
  #   GET  /api/keys/<pubkey>        the account a working key signs for
  #   GET  /api/ratings              this server's ratings of other accounts, and what each is made of
  #   POST /api/adjustments          an app beside this server moving an account's rating (local listener only)
  #   GET  /api/frontier             records nothing here acknowledges yet
  #   POST /api/records              {"records": [...]} or one record; each is checked (signed upload,
  #                                  except on the local listener)
  #   POST /api/introduce            {"declaration": ...}: an account's first declaration, so it can sign uploads
  #   GET  /api/sweep                ?account=&generation=&part=: the chain in parts, for catching up
  #   POST /api/sync                 {"heartbeat": ...}: a peer's newest heartbeat, its clock checked (signed upload)
  #
  # A signed upload carries the headers UploadAuth names, signed by an account
  # on this server's chain with its current working or master key. Reading
  # needs nothing. On the local listener (LocalListener), which only the apps
  # beside this server can reach, uploads need no signature.
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
      attr_accessor :store, :ingest, :host, :genesis, :settings, :clock, :accounts, :limiter, :ratings, :state,
                    :local_socket
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

        r.post("sync") { sync(r, uploader!(r)) }
        r.post("introduce") { introduce(r) }
        r.get("sweep") { sweep(r) }

        # What an app reads to decide what to show. States change as records
        # arrive, so these are asked, not kept.
        r.post("states") do
          hashes = r.POST.is_a?(Hash) ? r.POST["hashes"] : nil
          bounded!(r, hashes, "hashes")
          { "states" => accounts.states(hashes.select { |h| Record.hash?(h) }) }
        end

        r.on "accounts" do
          r.is do
            r.post do
              ids = r.POST.is_a?(Hash) ? r.POST["accounts"] : nil
              bounded!(r, ids, "accounts")
              { "accounts" => ids.select { |a| Record.hash?(a) }.filter_map { |a| accounts.summary(a) } }
            end
          end
          r.get(String) do |id|
            (Record.hash?(id) && accounts.summary(id)) || r.halt(404, { "error" => "no account #{id[0, 64]} here" })
          end
        end

        r.get("keys", String) { |pubkey| { "account" => accounts.account_for(pubkey) } }

        # What this server rates each account it has an opinion of, and what
        # that is made of: by hand, by reachability, and each app's
        # adjustment. The apps beside it read this to
        # choose which of their peers to ask for things the chain does not
        # carry, such as files.
        r.get("ratings") { { "ratings" => server.ratings ? server.ratings.current : {} } }

        # An app beside this server moving an account's rating by its own
        # judgement. Taken only on the local listener, so only those apps can.
        r.post("adjustments") { adjust(r) }

        r.on "records" do
          r.is do
            r.get { page(r) }
            r.post do
              uploader!(r) unless local?(r)
              post(r)
            end
          end
          r.get(String) do |hash|
            record = Record.hash?(hash) && store.fetch(hash)
            record ? record.to_wire.merge("state" => accounts.state(hash)) : r.halt(404, { "error" => "no record #{hash[0, 64]} here" })
          end
        end
      end
    end

    private

    def server = self.class

    def store = server.store

    def accounts = server.accounts

    # Whether the request came in on the local listener's socket.
    def local?(r) = LocalListener.local?(r.env, server.local_socket)

    # An app's name, as the further part of its record types gives it (:chat).
    APP_NAME = /\A[a-z][a-z0-9_]{0,31}\z/

    # {"app", "account", "reputation", "trust"}: one adjustment per app and
    # account, replacing the last; "0" and "0" clears it.
    def adjust(r)
      unless local?(r)
        r.halt(403, { "error" => "adjustments are taken only on the local listener, from the apps beside this server" })
      end
      body = r.POST.is_a?(Hash) ? r.POST : {}
      app = body["app"]
      account = body["account"]
      r.halt(400, { "error" => "app is an app's name, such as chat" }) unless app.is_a?(String) && app.match?(APP_NAME)
      r.halt(400, { "error" => "account is not an account ID" }) unless Record.hash?(account)
      r.halt(400, { "error" => "this server does not rate its own account" }) if account == server.host.id
      %w[reputation trust].each do |name|
        value = body[name]
        next if Formats.decimal?(value) && Formats.decimal(value).abs <= 1

        r.halt(400, { "error" => "#{name} is a decimal from -1 to 1, spelled as the rules spell one ('0.5', not '.5')" })
      end

      if body["reputation"] == "0" && body["trust"] == "0"
        store.clear_adjustment(app, account)
      else
        store.adjust_rating(app, account, reputation: body["reputation"], trust: body["trust"], at: server.clock.call)
      end
      { "account" => account, "rating" => server.ratings&.current&.[](account) }
    end

    def bounded!(r, list, name)
      r.halt(400, { "error" => "#{name} must be a list" }) unless list.is_a?(Array)
      r.halt(413, { "error" => "over #{limit('batch_records')} #{name} in one request" }) if list.size > limit("batch_records")
    end

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
    # The account that signed this upload; halts with 401 when none did, and
    # 403 when it is one this server ignores.
    def uploader!(r)
      now = server.clock.call
      account = UploadAuth.verify!(r.env, store: store, genesis: server.genesis, now: now,
                                          skew: server.settings.integer("peers", "max_clock_skew_seconds"))
      r.halt(403, { "error" => "this server ignores #{account}" }) if store.ignored?(account, at: now)
      account
    rescue UploadAuth::Refused => e
      r.halt(401, { "error" => e.message, "unknown_account" => e.unknown_account })
    end

    # An account not yet on this server's chain sends its first identity
    # declaration, and nothing else, so it can then sign uploads. The
    # declaration is checked like any record: its signature proves the key,
    # and the rules decide whether it joins.
    def introduce(r)
      wait = server.limiter.wait("introduce:#{r.ip}")
      if wait
        response["retry-after"] = wait.to_s
        r.halt(429, { "error" => "too many introductions; ask again in #{wait} seconds" })
      end

      body = r.POST
      record = Record.from_wire(body.is_a?(Hash) ? body["declaration"] : nil)
      unless record.digest && record.first_declaration?
        r.halt(400, { "error" => "an introduction is an account's first identity declaration" })
      end

      result = server.ingest.submit(record).to_h
      response.status = 202 if result["status"] == "pending"
      { "results" => [result] }
    rescue ArgumentError, Canonical::NotCanonical
      r.halt(400, { "error" => "an introduction is an account's first identity declaration" })
    end

    def sync(r, uploader)
      body = r.POST
      record = Record.from_wire(body.is_a?(Hash) ? body["heartbeat"] : nil)
      r.halt(400, { "error" => "heartbeat must be a heartbeat record" }) unless heartbeat?(record)

      author = record.account
      r.halt(403, { "error" => "a server shares its own heartbeat; #{uploader} signed one of #{author}'s" }) unless
        author == uploader
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
