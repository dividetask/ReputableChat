# frozen_string_literal: true

# The genesis account or the host account, driven from a terminal.
#
#   bundle exec ruby script/tim.rb status
#   bundle exec ruby script/tim.rb --host post "Planned outage 02:00-03:00 UTC on Friday"
#   bundle exec ruby script/tim.rb friend <account ID>
#   bundle exec ruby script/tim.rb --host visible <account ID>
#
# Signs as the genesis account (the developer's) by default, and as this
# server's host account with --host. Nothing enforces who signs what, but by
# convention the genesis account signs what covers the whole network -- releases
# and the rules -- and the host account signs what concerns one server, such as
# an outage.
#
# Reads the seed written by `rake genesis` or `rake host`,
# derives the same key the browser would from the same phrase, and talks to a
# running server over the ordinary API. Nothing here is a back door: every
# request is signed and the server verifies it exactly as it verifies a
# browser's.
#
# `visible` is the useful one for a new network. An unrated account sits at
# exactly zero and is therefore invisible to everyone -- that is the sybil
# defense, and it also means nobody can get started. One positive rating from
# the account is enough to lift somebody over the line for anyone who rates
# that account.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "net/http"
require "uri"
require "reputable_chat/config"
require "reputable_chat/genesis"
require "reputable_chat/host"
require "reputable_chat/operator"
require "reputable_chat/server_config"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/vault"
require "reputable_chat/chain/record"
require "reputable_chat/reputation/engine"
require "reputable_chat/store/memory"

module Tim
  Crypto   = ReputableChat::Cryptography
  Payload  = Crypto::Payload
  MAX_BODY = 4_000
  DEFAULT_URL = "http://localhost:9292"

  class Failed < StandardError; end

  # --- talking to the server ---------------------------------------------

  # Challenge-response, the same three steps the browser takes: ask for a
  # nonce, sign {purpose, pubkey, nonce, origin, ts}, present it. `origin` is
  # inside the signature, so it has to be one the server accepts: the address
  # we dial, unless --origin says otherwise.
  class Client
    attr_reader :pubkey, :vault_key, :account, :latest

    def initialize(url:, origin:, private_key:, pubkey:, vault_key:)
      @base = URI.parse(url)
      @origin = origin
      @private_key = private_key
      @pubkey = pubkey
      @vault_key = vault_key
      @cookie = nil
    end

    def log_in
      nonce = post_json("/api/challenge", {}).fetch("nonce")
      ts = Time.now.to_i
      payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: @origin, issued_at: ts)

      body = { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }
      result = post_json("/api/session", body)

      # The genesis is every server's root and the host account's declaration
      # joins a server at boot, so either is known to any server running it.
      unless result["registered"]
        raise Failed, "the server knows no account for #{@pubkey}. Is it running the same " \
                      "genesis and host account as this checkout?"
      end
      @account = result["account"]
      @latest = result["latest"]
      self
    end

    def sign(payload) = ReputableChat::Operator.sign(@private_key, payload)

    # Signs a record and sends it. Returns its record hash, and remembers it as
    # this account's latest, which the next record acknowledges.
    def publish(payload)
      canonical = Crypto::Canonical.dump(payload)
      result = post_json("/api/record", { "payload" => canonical, "signature" => sign(canonical) })
      @latest = result.fetch("hash")
    end

    def get_json(path) = request(Net::HTTP::Get.new(path))

    def post_json(path, body) = request(json_request(Net::HTTP::Post, path, body))

    def put_json(path, body) = request(json_request(Net::HTTP::Put, path, body))

    private

    def json_request(klass, path, body)
      request = klass.new(path)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
      request
    end

    def request(request)
      request["Cookie"] = @cookie if @cookie
      response = Net::HTTP.start(@base.host, @base.port, use_ssl: @base.scheme == "https") do |http|
        http.request(request)
      end

      @cookie = response["Set-Cookie"].split(";").first if response["Set-Cookie"]
      parsed = JSON.parse(response.body.to_s.empty? ? "{}" : response.body)

      raise Failed, (parsed["error"] || "#{response.code} from #{request.path}") unless response.is_a?(Net::HTTPSuccess)

      parsed
    rescue Errno::ECONNREFUSED
      raise Failed, "nothing is listening on #{@base}. Start the server, or pass --url."
    rescue JSON::ParserError
      raise Failed, "#{request.path} did not return JSON (#{response.code})"
    end
  end

  module_function

  # --- commands -----------------------------------------------------------

  def run(argv)
    options = parse(argv)
    command = options[:command]

    case command
    when "status"  then status(options)
    when "post"    then post(options)
    when "friend"  then rate(options, :friend)
    when "visible" then rate(options, :visible)
    else usage
    end
  rescue Failed, ReputableChat::Operator::MissingSeed, ReputableChat::Genesis::Missing,
         ReputableChat::Host::Missing, Crypto::Seed::InvalidSeed => e
    abort "  #{e.message}"
  end

  def status(options)
    client = connect(options)
    declaration = own_identity(client, options)
    vault = own_vault(client)
    ratings = vault.fetch("ratings")

    puts
    puts "  Account      #{options[:account] == :host ? 'host' : 'genesis'}"
    puts "  Handle       #{declaration['title']}"
    puts "  Account ID   #{client.account}"
    puts "  Working key  #{client.pubkey}"
    puts "  Genesis      #{ReputableChat::Genesis.current.hash}"
    puts "  Host         #{ReputableChat::Host.current&.hash || 'none on this server'}"
    puts "  Attestation  #{attestation(client) ? 'published' : 'none yet'}, " \
         "#{ratings.size} #{ratings.size == 1 ? 'rating' : 'ratings'}"
    puts "  Vault        revision #{vault['revision']} (private: the server cannot read it)"
    puts

    return puts("  Nobody rated yet.\n\n") if ratings.empty?

    engine = engine_for(client.account, ratings)
    ratings.each do |target, rating|
      effective = engine.effective(viewer: client.account, target: target)
      puts format("  %-45s %-9s %s", target, label(rating), effective.round(6).to_s("F"))
    end
    puts
  end

  # A message from the account: a planned outage, a new feature.
  def post(options)
    body = options[:args].join(" ").strip
    abort "  nothing to post" if body.empty?
    abort "  too long: #{body.bytesize} bytes, the limit is #{MAX_BODY}" if body.bytesize > MAX_BODY

    client = connect(options)
    messages = client.get_json("/api/messages").fetch("messages")

    ack = choose_ack(client, messages)
    payload = Payload.message(id: client.account, pubkey: client.pubkey, body: body,
                              ack: ack, ts: Time.now.to_i)
    hash = client.publish(payload)

    puts
    puts "  Posted."
    puts "  Record  #{hash}"
    ack.each do |acked|
      puts "  Ack     #{acked}#{acked == ReputableChat::Genesis.current.hash ? '  (genesis)' : ''}"
    end
    puts
  end

  # `friend` is the strong vouch. `visible` is the weak one: the least rating
  # that lifts somebody over the visibility line, for saying "this is a real
  # person" without saying "I know them".
  def rate(options, kind)
    target = options[:args].first
    abort "  usage: #{kind} <account ID>" unless target
    abort "  that is not an account ID: a 64-character record hash" unless ReputableChat::Params.record_hash(target)

    client = connect(options)
    abort "  that is this account's own ID" if target == client.account

    vault = own_vault(client)
    ratings = vault.fetch("ratings")
    before = ratings[target]

    ratings[target] = kind == :friend ? friended(before) : made_visible(before)
    # The vault first. It is the only copy of the decision -- an attestation
    # carries what the decision came to, not the decision -- so a failure after
    # this point loses a published number that can be republished, rather than
    # the rating it was computed from.
    push_vault(client, vault)
    publish_attestation(client, ratings)

    engine = engine_for(client.account, ratings)
    puts
    puts "  #{target}"
    puts "  #{label(before) || 'unrated'} -> #{label(ratings[target])}"
    puts "  effective #{engine.effective(viewer: client.account, target: target).round(6).to_s('F')} " \
         "(#{engine.bucket(viewer: client.account, target: target)})"
    puts
  end

  # --- rating shapes ------------------------------------------------------

  def blank_rating = { "friend" => false, "reported" => false, "net_votes" => 0, "cleared" => false }

  def friended(before)
    (before || blank_rating).merge("friend" => true, "reported" => false, "cleared" => false)
  end

  # The smallest vote count that clears the visibility line, read off the curve
  # rather than hardcoded, so retuning the curve moves this with it. Never
  # lowers somebody who is already above the line.
  def made_visible(before)
    current = before || blank_rating
    votes = [current["net_votes"].to_i, minimum_visible_votes].max

    current.merge("reported" => false, "cleared" => false, "net_votes" => votes)
  end

  def minimum_visible_votes
    config = ReputableChat::Config.load
    engine = ReputableChat::Reputation::Engine.new(config: config, store: ReputableChat::Store::Memory.new)
    line = config.decimal("display.visible_above")
    weight = engine.ladder.weight(0)

    (1..engine.curve.saturation_point).find { |n| weight * engine.curve.value(n) > line } ||
      engine.curve.saturation_point
  end

  def label(rating)
    return nil unless rating
    return "reported" if rating["reported"]
    return "friend" if rating["friend"]
    return "cleared" if rating["cleared"]

    "+#{rating['net_votes']}"
  end

  # --- the identity declaration --------------------------------------------

  # Falls back to the committed record, which is itself an identity
  # declaration: the handle and bio the account was created with are the ones
  # the network sees rather than a placeholder that has to be corrected later.
  def own_identity(client, options)
    blob = client.get_json("/api/identity/#{client.account}")["identity"]
    return committed(options).declaration if blob.nil?

    JSON.parse(blob["payload"])
  end

  # --- the vault ------------------------------------------------------------

  # Friending, reporting and voting are private. They live in the vault, sealed
  # with a key the server does not have, and only what they come to is
  # published. So this is where a rating is read and written; the attestation
  # is downstream of it.
  #
  # A vault that will not open is raised on rather than replaced with a blank
  # one. The browser can afford to shrug one off and carry on, because a person
  # is sitting there; here a blank vault would be published as an attestation
  # that silently unfriends everybody.
  def own_vault(client)
    blob = client.get_json("/api/vault")["vault"]
    return { "revision" => 0, "ratings" => {}, "contents" => {} } if blob.nil?

    payload = JSON.parse(blob["payload"])
    contents = Crypto::Vault.unseal(client.vault_key,
                                    ciphertext: payload["ciphertext"], iv: payload["iv"])
    raise Failed, "the stored vault will not open with this seed. Wrong seed file, " \
                  "or a changed seed.kdf.vault_domain." if contents.nil?

    { "revision" => payload["revision"].to_i, "ratings" => contents["ratings"] || {},
      "contents" => contents }
  end

  # Everything the vault held is written back, not just the ratings: a browser
  # keeps the friend order, the seen set and the settings in here too, and this
  # must not be the thing that drops them.
  def push_vault(client, vault)
    revision = vault["revision"].to_i + 1
    contents = vault["contents"].merge("ratings" => vault["ratings"])
    sealed = Crypto::Vault.seal(client.vault_key, contents)
    ts = Time.now.to_i

    payload = Payload.vault(pubkey: client.pubkey, revision: revision,
                            ciphertext: sealed["ciphertext"], iv: sealed["iv"], issued_at: ts)

    client.put_json("/api/vault", sealed.merge("revision" => revision, "ts" => ts,
                                               "signature" => client.sign(payload)))
  end

  # --- the attestation ------------------------------------------------------

  def attestation(client) = client.get_json("/api/attestation/#{client.account}")["attestation"]

  # What the vault's private actions come to, as numbers. The curve runs here,
  # once, rather than in every reader -- that is the whole difference between an
  # attestation and the config it replaces.
  #
  # No derived: that is the author's calculated reputations for everyone their
  # walk reached, and this CLI does not walk -- it never fetches anybody else's
  # attestation. Leaving it out says exactly that, where a hop-0 answer
  # published as though it were a walk would offer readers a cache that is
  # wrong rather than absent.
  def publish_attestation(client, ratings)
    messages = client.get_json("/api/messages").fetch("messages")
    payload = Payload.attestation(id: client.account, pubkey: client.pubkey, scores: scores_for(ratings),
                                  ack: choose_ack(client, messages), ts: Time.now.to_i)
    client.publish(payload)
  end

  def scores_for(ratings)
    engine = engine_for("self", ratings)
    friend_value = ReputableChat::Config.load.decimal("actions.friend.value")

    ratings.each_with_object({}) do |(target, rating), out|
      score = ReputableChat::Reputation::Rating.from_h(rating)
      value = score.value(curve: engine.curve, friend_value: friend_value)

      out[target] = { "reputation" => decimal(value),
                      "trust" => decimal(value > 0 ? ReputableChat::Reputation::ONE : ReputableChat::Reputation::ZERO) }
    end
  end

  # The same text the browser writes for the same number. Shared rather than
  # reimplemented here, because two producers of a signed field that agree on
  # the value and differ on its spelling is a trap rather than a difference.
  def decimal(value)
    ReputableChat::Reputation.decimal(value, ReputableChat::Config.load.scale)
  end

  # --- the chain ----------------------------------------------------------

  # This account's own latest record, and the most recent message whose author
  # clears the bar, falling back to the genesis. This is a hop-0 answer: the
  # CLI has only its own ratings in hand, so it is the same number the engine
  # would give with nobody else's attestation fetched, not a full walk.
  def choose_ack(client, messages)
    config = ReputableChat::Config.load
    bar = config.decimal("chain.min_reputation_to_acknowledge")
    engine = engine_for(client.account, own_vault(client).fetch("ratings"))

    hit = messages.reverse.find do |message|
      next false if message["state"] == "void"
      next true if message["account"] == client.account

      engine.effective(viewer: client.account, target: message["account"]) > bar
    end

    ack = [hit&.fetch("hash"), client.latest].compact.uniq
    ack.empty? ? [ReputableChat::Genesis.current.hash] : ack
  end

  def engine_for(viewer, ratings)
    store = ReputableChat::Store::Memory.new
    ratings.each do |target, rating|
      store.rate(viewer, target,
                 friend: rating["friend"], reported: rating["reported"],
                 net_votes: rating["net_votes"].to_i, cleared: rating["cleared"])
    end

    ReputableChat::Reputation::Engine.new(config: ReputableChat::Config.load, store: store)
  end

  # --- wiring -------------------------------------------------------------

  def connect(options)
    phrase = ReputableChat::Operator.seed_phrase(path: options[:seed_path])
    warn "  warning: #{options[:seed_path]} is readable by other users on this machine" if
      ReputableChat::Operator.seed_readable_by_others?(path: options[:seed_path])

    keys = ReputableChat::Operator.derive(phrase)
    expected = committed(options).pubkey
    unless keys["pubkey"] == expected
      abort "  the seed derives #{keys['pubkey']} but the committed #{options[:account]} account is " \
            "#{expected}. Wrong seed file, or a changed seed.kdf.domain."
    end

    # The raw Argon2id output IS the Ed25519 private key, and the vault key is
    # HKDF over it under a separate domain -- one derivation, two keys, exactly
    # as public/js/vault.js does it in the browser.
    vault_key = Crypto::Vault.derive_key(
      Crypto::Vault.from_b64url(keys["private_key"]),
      ReputableChat::Config.load.fetch("seed.kdf.vault_domain")
    )

    Client.new(url: options[:url], origin: options[:origin], private_key: keys["private_key"],
               pubkey: keys["pubkey"], vault_key: vault_key).log_in
  end

  # The committed record of whichever account this run signs as.
  def committed(options)
    return ReputableChat::Genesis.current unless options[:account] == :host

    ReputableChat::Host.current or
      raise ReputableChat::Host::Missing, ReputableChat::Host.missing_message(ReputableChat::Host.path)
  end

  def parse(argv)
    settings = ReputableChat::ServerConfig.load
    options = { command: nil, args: [], origin: nil, url: nil,
                seed_path: nil, account: :genesis }

    until argv.empty?
      flag = argv.shift
      case flag
      when "--origin" then options[:origin]    = argv.shift.to_s
      when "--url"    then options[:url]       = argv.shift.to_s
      when "--seed"   then options[:seed_path] = File.expand_path(argv.shift.to_s)
      when "--host"   then options[:account]   = :host
      when "--help", "-h" then usage
      else options[:command] ? options[:args] << flag : options[:command] = flag
      end
    end

    # The URL is where we dial; the origin is what goes inside the signature.
    # By default they are the same address, which is what a server with no
    # origin configured expects. They differ when the server is reached over a
    # tunnel or on localhost while configured with its public name.
    options[:url] ||= options[:origin] || settings.fetch("origin").first || DEFAULT_URL
    options[:origin] = ReputableChat::Origin.normalize(options[:origin] || options[:url]) or
      abort "  not an http(s) address: #{(options[:origin] || options[:url]).inspect}"
    options[:seed_path] ||= ReputableChat::Operator.seed_path(account: options[:account])
    options
  end

  def usage
    puts <<~TEXT

      usage: bundle exec ruby script/tim.rb <command> [options]

        status              who the account is, and everyone it has rated
        post <text>         send a message
        friend <account>    friend somebody, by account ID
        visible <account>   lift somebody to the least rating that makes them
                            visible, without claiming to know them

      options:
        --host              sign as this server's host account rather than the
                            genesis account
        --url URL           where to reach the server (default: --origin, else the
                            first origin in config/server.yml, else #{DEFAULT_URL})
        --origin ORIGIN     the origin inside the signature (default: the URL)
        --seed FILE         seed file (default: config/genesis/<env>.seed,
                            or config/host/<env>.seed with --host)

    TEXT
    exit 0
  end
end

require "reputable_chat/params"
Tim.run(ARGV) if $PROGRAM_NAME == __FILE__
