# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "record"
require_relative "upload_auth"
require_relative "view"

module Agnostic
  # Exchanging records with other servers, once per heartbeat.
  #
  # Each time this server publishes a heartbeat it syncs with every peer:
  #
  # 1. Share the new heartbeat (POST /api/sync). The peer checks its ts
  #    against its own clock and ignores this server for good if the two are
  #    more than ten minutes apart -- a server whose clock is that far off is
  #    taken to be lying about time.
  # 2. The peer, checking the heartbeat, asks for every record in its
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
    def initialize(store:, ingest:, settings:, http: nil, clock: -> { Time.now.to_i }, host: nil,
                   sleeper: ->(seconds) { sleep seconds })
      @sleeper = sleeper
      @clock = clock
      @store = store
      @ingest = ingest
      @settings = settings
      @host = host
      @http = http || method(:request)
      ingest.on_accept { |record, _source| learn(record) }
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
      return if @host&.id && record.account == @host.id

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

    # --- catching up -----------------------------------------------------------

    # A request a server answered with an error status.
    class HttpError < StandardError
      attr_reader :status, :retry_after, :body

      def initialize(message, status:, retry_after: nil, body: nil)
        super(message)
        @status = status
        @retry_after = retry_after
        @body = body
      end
    end

    # Sweeps the chain before going live, from several servers at once.
    #
    # Generations are counted by one account that publishes heartbeats -- the
    # first server's own -- so they mean the same on every server holding its
    # heartbeats, and each server can be asked for different ones. Up to one
    # generation per server is fetched in parallel; they are checked in order,
    # each record after everything it acknowledges. Progress is kept per
    # account, so a sweep resumes where it stopped. Returns how many records
    # were new here.
    def catch_up(urls)
      sources = urls.select { |url| contact(url) }
      return 0 if sources.empty?

      account = get(sources.first, "/api")["host"]
      reach = sources.to_h { |url| [url, latest_generation(url, account)] }.select { |_, latest| latest }
      top = reach.values.max.to_i
      generation = (@store.meta("sweep:#{account}") || "1").to_i
      added = 0
      while generation <= top
        batch = (generation..[generation + reach.size - 1, top].min).to_a
        threads = batch.each_with_index.map do |g, i|
          holders = reach.keys.rotate(i).select { |url| reach[url] >= g }
          Thread.new { fetch_generation(account, g, holders) }
        end
        batch.zip(threads.map(&:value)).each do |g, records|
          return added unless records

          added += records.count { |wire| @ingest.submit(Record.from_wire(wire), source: :sweep).status == :accepted }
          @store.save_meta("sweep:#{account}", g + 1)
        end
        generation = batch.last + 1
      end
      reach.each_key { |url| reached(url) }
      added
    end

    def latest_generation(url, account)
      Integer(sweep_request(url, account, 1, 0)["latest"])
    rescue StandardError => e
      failed(url, "sweep failed: #{e.message}")
      nil
    end

    # Every part of one generation, from the first of these servers that
    # gives all of it; nil when none does.
    def fetch_generation(account, generation, holders)
      holders.each do |url|
        records = []
        part = 0
        loop do
          body = sweep_request(url, account, generation, part)
          records.concat(Array(body["records"]))
          following = body["next"]
          break unless following.is_a?(Hash) && following["generation"] == generation

          part = Integer(following["part"])
        end
        return records
      rescue StandardError => e
        warn "#{url}: generation #{generation} of #{account} failed: #{e.message}"
      end
      nil
    end

    # Waits as long as a server asks, a few times, when it is asked too often.
    def sweep_request(url, account, generation, part)
      attempts = 0
      begin
        get(url, "/api/sweep?account=#{account}&generation=#{generation}&part=#{part}")
      rescue HttpError => e
        raise unless e.status == 429 && (attempts += 1) <= 3

        @sleeper.call([e.retry_after.to_i, 1].max)
        retry
      end
    end

    # --- chain splits ------------------------------------------------------------

    # After catching up: takes each server's latest records -- what nothing on
    # it acknowledges yet -- with whatever of their history is missing here,
    # and looks for a chain split (section 10): a server holding a record the
    # rules refuse for holding both sides of one, or the servers' latest
    # records, taken together, holding a record and the heartbeat that
    # orphaned it. Returns what it found (problems, one line each, empty when
    # nothing), each server's latest records (tips), and the record and
    # heartbeat of each split found (pairs).
    def check_splits(urls)
      problems = []
      latest = []
      tips_of = {}
      budget = @settings.integer("peers", "fetch_missing")
      urls.each do |url|
        next unless contact(url)

        tips = Array(get(url, "/api/frontier")["records"]).select { |h| Record.hash?(h) }
        queue = tips.dup
        while (hash = queue.shift)
          next if @store.known?(hash)

          if (budget -= 1).negative?
            problems << "#{url}: more of its latest records than peers.fetch_missing allows to fetch"
            break
          end
          result = @ingest.submit(Record.from_wire(get(url, "/api/records/#{hash}")), source: url)
          queue.concat(Array(result.missing)) if result.status == :pending
          orphan = Array(result.problems).find { |p| p.include?("orphaned") }
          problems << "#{url} holds #{hash}, which #{orphan.sub(/\Athe history/, 'has a history that')}" if orphan
        end
        tips_of[url] = tips.select { |h| @store.known?(h) }
        latest.concat(tips_of[url])
      rescue StandardError => e
        failed(url, "split check failed: #{e.message}")
      end

      view = View.new(store: @store, histories: Histories.new(@store), hashes: @store.closure(latest.uniq),
                      genesis: @ingest.rules.genesis.digest)
      together = []
      @ingest.rules.split(nil, view, together)
      problems += together.map { |p| "the servers' latest records together: #{p}" }
      pairs = problems.filter_map { |p| p.match(/holds ([0-9a-f]{64}) and ([0-9a-f]{64}), a heartbeat/)&.captures }.uniq
      { problems: problems, tips: tips_of, pairs: pairs }
    end

    # --- sync ------------------------------------------------------------------

    # Called with each heartbeat this server publishes.
    # Only the heartbeat goes unasked: the peer may have seen everything else
    # already, so it asks for what it lacks instead.
    def sync(beat)
      urls.each do |url|
        next unless contact(url)

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
      return false if @host&.id && host == @host.id

      !(host && @store.ignored?(host, at: @clock.call))
    rescue StandardError => e
      failed(url, "unreachable: #{e.message}")
      false
    end

    def own?(peer) = @host&.id && peer[:host] == @host.id

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

    private

    def get(url, path) = @http.call(:get, url + path, nil, {})

    # Uploads are signed by this server's host account. A peer that has not
    # seen the account yet is first sent its declaration, then asked again.
    def post(url, path, body, introduced: false)
      json = JSON.generate(body)
      headers = UploadAuth.headers(@host, :post, URI(url + path).path, json, @clock.call)
      @http.call(:post, url + path, json, headers)
    rescue HttpError => e
      raise unless e.status == 401 && e.body.is_a?(Hash) && e.body["unknown_account"] && !introduced

      introduce(url)
      post(url, path, body, introduced: true)
    end

    def introduce(url)
      @http.call(:post, url + "/api/introduce", JSON.generate("declaration" => @host.declaration.to_wire), {})
    end

    def request(method, address, body, headers)
      uri = URI(address)
      timeout = @settings.integer("peers", "timeout_seconds")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: timeout, read_timeout: timeout) do |http|
        request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        headers.each { |name, value| request[name] = value }
        if body
          request["Content-Type"] = "application/json"
          request.body = body
        end
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          parsed = begin
            JSON.parse(response.body.to_s)
          rescue JSON::ParserError
            nil
          end
          raise HttpError.new("#{method.upcase} #{address} answered #{response.code}",
                              status: response.code.to_i, retry_after: response["retry-after"], body: parsed)
        end

        JSON.parse(response.body)
      end
    end
  end
end
