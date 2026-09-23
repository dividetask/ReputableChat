# frozen_string_literal: true

# The genesis account, driven from a terminal.
#
#   bundle exec ruby script/tim.rb status
#   bundle exec ruby script/tim.rb post "Planned outage 02:00-03:00 UTC on Friday"
#   bundle exec ruby script/tim.rb friend <pubkey>
#   bundle exec ruby script/tim.rb visible <pubkey>
#
# Reads the seed written by `rake genesis` (config/genesis/seed, gitignored),
# derives the same key the browser would from the same phrase, and talks to a
# running server over the ordinary API. Nothing here is a back door: every
# request is signed and the server verifies it exactly as it verifies a
# browser's.
#
# `visible` is the useful one for a new network. An unrated account sits at
# exactly zero and is therefore invisible to everyone -- that is the sybil
# defense, and it also means nobody can get started. One positive rating from
# the genesis account is enough to lift somebody over the line for anyone who
# rates the genesis account.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "net/http"
require "uri"
require "reputable_chat/config"
require "reputable_chat/genesis"
require "reputable_chat/operator"
require "reputable_chat/server_config"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/record"
require "reputable_chat/reputation/engine"
require "reputable_chat/store/memory"

module Tim
  Crypto   = ReputableChat::Cryptography
  Payload  = Crypto::Payload
  ROOM     = "general"
  MAX_BODY = 4_000

  class Failed < StandardError; end

  # --- talking to the server ---------------------------------------------

  # Challenge-response, the same three steps the browser takes: ask for a
  # nonce, sign {purpose, pubkey, nonce, origin, ts}, present it. `origin` is
  # inside the signature, so it has to be the origin the server is configured
  # with rather than the URL we happened to dial.
  class Client
    attr_reader :pubkey

    def initialize(url:, origin:, private_key:, pubkey:)
      @base = URI.parse(url)
      @origin = origin
      @private_key = private_key
      @pubkey = pubkey
      @cookie = nil
    end

    def log_in
      nonce = post_json("/api/challenge", {}).fetch("nonce")
      ts = Time.now.to_i
      payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: @origin, issued_at: ts)

      body = { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }
      result = post_json("/api/session", body)

      register unless result["registered"]
      self
    end

    # A valid but unregistered key reaches here the first time the genesis
    # account is used against a fresh database.
    def register = post_json("/api/register", {})

    def sign(payload) = ReputableChat::Operator.sign(@private_key, payload)

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
         Crypto::Seed::InvalidSeed => e
    abort "  #{e.message}"
  end

  def status(options)
    client = connect(options)
    config = own_config(client)
    ratings = config["ratings"]

    puts
    puts "  Handle       #{config['profile']['username']}"
    puts "  Public key   #{client.pubkey}"
    puts "  Genesis      #{ReputableChat::Genesis.current.hash}"
    puts "  Config       revision #{config['revision']}, #{ratings.size} #{ratings.size == 1 ? 'rating' : 'ratings'}"
    puts

    return puts("  Nobody rated yet.\n\n") if ratings.empty?

    engine = engine_for(client.pubkey, ratings)
    ratings.each do |target, rating|
      effective = engine.effective(viewer: client.pubkey, target: target)
      puts format("  %-45s %-9s %s", target, label(rating), effective.round(6).to_s("F"))
    end
    puts
  end

  # An announcement from the genesis account: a planned outage, a new feature.
  def post(options)
    body = options[:args].join(" ").strip
    abort "  nothing to post" if body.empty?
    abort "  too long: #{body.bytesize} bytes, the limit is #{MAX_BODY}" if body.bytesize > MAX_BODY

    client = connect(options)
    room = options[:room]
    messages = client.get_json("/api/room/#{room}/messages").fetch("messages")

    seq = messages.select { |m| m["author"] == client.pubkey }.map { |m| m["seq"].to_i }.max.to_i + 1
    ack = choose_ack(client, messages)
    ts = Time.now.to_i

    # `prev` stays nil, matching the browser. Chaining an author's own messages
    # is not implemented anywhere yet, and a chain that is right within one
    # room and silently skips in another is worse than an absent one.
    payload = Payload.message(author: client.pubkey, room: room, seq: seq, prev: nil,
                              body: body, ack: ack, issued_at: ts, note: options[:note])
    canonical = Crypto::Canonical.dump(payload)
    signature = client.sign(payload)

    client.post_json("/api/room/#{room}/message",
                     { "seq" => seq, "prev" => nil, "ack" => ack, "body" => body,
                       "note" => options[:note], "ts" => ts, "signature" => signature })

    # The same hash the server derived, from the same two strings.
    hash = Crypto::Record.digest(payload: canonical, signature: signature)
    puts
    puts "  Posted to ##{room} as ##{seq}."
    puts "  Record  #{hash}"
    puts "  Ack     #{ack}#{ack == ReputableChat::Genesis.current.hash ? '  (genesis)' : ''}"
    puts "  Note    #{options[:note]}" if options[:note]
    puts
  end

  # `friend` is the strong vouch. `visible` is the weak one: the least rating
  # that lifts somebody over the visibility line, for saying "this is a real
  # person" without saying "I know them".
  def rate(options, kind)
    target = options[:args].first
    abort "  usage: #{kind} <pubkey>" unless target
    abort "  that is not a public key" unless ReputableChat::Params.pubkey(target)

    client = connect(options)
    abort "  that is the genesis account's own key" if target == client.pubkey

    config = own_config(client)
    ratings = config["ratings"]
    before = ratings[target]

    ratings[target] = kind == :friend ? friended(before) : made_visible(before)
    publish(client, config)

    engine = engine_for(client.pubkey, ratings)
    puts
    puts "  #{target}"
    puts "  #{label(before) || 'unrated'} -> #{label(ratings[target])}"
    puts "  effective #{engine.effective(viewer: client.pubkey, target: target).round(6).to_s('F')} " \
         "(#{engine.bucket(viewer: client.pubkey, target: target)})"
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
    ReputableChat::Reputation::Engine.new(
      config: ReputableChat::Config.load, store: ReputableChat::Store::Memory.new
    ).minimum_visible_votes
  end

  def label(rating)
    return nil unless rating
    return "reported" if rating["reported"]
    return "friend" if rating["friend"]
    return "cleared" if rating["cleared"]

    "+#{rating['net_votes']}"
  end

  # --- config -------------------------------------------------------------

  # Seeded from the genesis record when there is no config yet, so the handle
  # and bio the chain was created with are the ones the network sees rather
  # than a placeholder that has to be corrected later.
  def own_config(client)
    blob = client.get_json("/api/config/#{client.pubkey}")["config"]
    return from_genesis if blob.nil?

    payload = JSON.parse(blob["payload"])
    { "revision" => payload["revision"].to_i, "profile" => payload["profile"], "ratings" => payload["ratings"] || {} }
  end

  def from_genesis
    record = JSON.parse(ReputableChat::Genesis.current.payload)

    { "revision" => 0, "ratings" => {},
      "profile" => { "username" => record["handle"], "message" => record["bio"], "icon" => record["icon"] } }
  end

  def publish(client, config)
    revision = config["revision"].to_i + 1
    ts = Time.now.to_i
    payload = Payload.config(pubkey: client.pubkey, revision: revision, profile: config["profile"],
                             ratings: config["ratings"], issued_at: ts)

    client.put_json("/api/config", { "revision" => revision, "profile" => config["profile"],
                                     "ratings" => config["ratings"], "ts" => ts,
                                     "signature" => client.sign(payload) })
  end

  # --- the chain ----------------------------------------------------------

  # The most recent message whose author clears the bar, falling back to the
  # genesis. This is a hop-0 answer: the CLI has only its own ratings in hand,
  # so it is the same number the engine would give with nobody else's config
  # fetched, not a full walk of the graph.
  def choose_ack(client, messages)
    config = ReputableChat::Config.load
    bar = config.decimal("chain.min_reputation_to_acknowledge")
    engine = engine_for(client.pubkey, own_config(client)["ratings"])

    hit = messages.reverse.find do |message|
      next false unless message["hash"]
      next true if message["author"] == client.pubkey

      engine.effective(viewer: client.pubkey, target: message["author"]) > bar
    end

    hit ? hit["hash"] : ReputableChat::Genesis.current.hash
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
    expected = ReputableChat::Genesis.current.pubkey
    unless keys["pubkey"] == expected
      abort "  the seed derives #{keys['pubkey']} but the committed genesis is #{expected}. " \
            "Wrong seed file, or a changed seed.kdf.domain."
    end

    Client.new(url: options[:url], origin: options[:origin],
               private_key: keys["private_key"], pubkey: keys["pubkey"]).log_in
  end

  def parse(argv)
    settings = ReputableChat::ServerConfig.load
    options = { command: nil, args: [], room: ROOM, origin: settings.fetch("origin"),
                url: nil, seed_path: ReputableChat::Operator.seed_path, note: nil }

    until argv.empty?
      flag = argv.shift
      case flag
      when "--room"   then options[:room]      = argv.shift.to_s
      when "--origin" then options[:origin]    = argv.shift.to_s
      when "--url"    then options[:url]       = argv.shift.to_s
      when "--seed"   then options[:seed_path] = File.expand_path(argv.shift.to_s)
      when "--note"   then options[:note]      = ReputableChat::Params.note(argv.shift)
      when "--help", "-h" then usage
      else options[:command] ? options[:args] << flag : options[:command] = flag
      end
    end

    # The URL is where we dial; the origin is what goes inside the signature.
    # They differ when the server is reached over a tunnel or on localhost
    # while configured with its public name.
    options[:url] ||= options[:origin]
    options
  end

  def usage
    puts <<~TEXT

      usage: bundle exec ruby script/tim.rb <command> [options]

        status              who the genesis account is, and everyone it has rated
        post <text>         post an announcement to a room
        friend <pubkey>     friend somebody
        visible <pubkey>    lift somebody to the least rating that makes them
                            visible, without claiming to know them

      options:
        --room NAME         room for `post` (default: #{ROOM})
        --note TEXT         free text signed into the record for anyone reading
                            the raw chain; the software never reads it
        --url URL           where to reach the server (default: the origin)
        --origin ORIGIN     the origin inside the signature (default: config/server.yml)
        --seed FILE         seed file (default: config/genesis/seed)

    TEXT
    exit 0
  end
end

require "reputable_chat/params"
Tim.run(ARGV) if $PROGRAM_NAME == __FILE__
