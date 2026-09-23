# frozen_string_literal: true

require_relative "brain"
require_relative "brains/scripted"
require_relative "brains/markov"
require_relative "brains/llm"
require_relative "categories"
require_relative "client"
require_relative "identity"
require_relative "roster"
require_relative "state"
require_relative "view"
require_relative "vouchers"
require_relative "../genesis"

module ReputableChat
  module Bot
    # One bot, living its life: away, then a visit, then away again.
    #
    # A visit is a login, which is also how the reputation rules want it --
    # buckets are sorted on arrival and hold until the bot comes back, so a
    # reaction it makes at 9pm changes nothing it can see until tomorrow.
    class Runner
      # How often a bot picks from the people its category is drawn to rather
      # than from whoever spoke last. Not total: a gullible account that only
      # ever answered scammers would be a caricature, and would never give the
      # network the honest activity that makes its vouching cost anything.
      ATTRACTION = 0.7

      # `speed` compresses the waiting so a week of a swarm can be watched over
      # lunch. It scales nothing but the sleeping: every rate and every
      # distribution stays exactly what the persona asked for.
      def initialize(persona:, name:, state:, client:, logger:, vouchers: nil, state_dir: nil,
                     random: Random.new, speed: 1.0, categories: Categories.current)
        @persona    = persona
        @name       = name
        @state      = state
        @client     = client
        @log        = logger
        @vouchers   = vouchers
        @state_dir  = state_dir || File.dirname(state.path)
        @random     = random
        @speed      = speed.to_f
        @categories = categories
        @sleep      = ->(seconds) { Kernel.sleep(seconds) }
      end

      # `visits` caps the run for a smoke test; nil means until killed.
      # `wait_first` is what keeps a fleet from arriving in lockstep, and is
      # exactly what you do not want when you are watching a single bot.
      def run(visits: nil, wait_first: true)
        @defaults = @client.defaults
        @emotes   = @client.emote_config
        @schedule = @persona.schedule(random: @random)
        @brain    = Brain.for(@persona, random: @random, links: safe_links, logger: @log)

        agree_on_genesis!

        log "#{@persona.category} | #{@schedule.summary}"

        ensure_account!
        wait(@schedule.initial_delay, "first visit") if wait_first

        count = 0
        loop do
          recycle_if_due!
          visit
          count += 1
          break if visits && count >= visits

          wait(@schedule.away_seconds, "away")
        end
      end

      private

      # The bottom of the chain has to be the same one the server is running,
      # or every `ack` this bot signs points at a record nobody else has. A
      # mismatch is a wrong checkout, not a hiccup, so it stops here.
      def agree_on_genesis!
        @genesis = Genesis.current
        served   = @client.genesis

        return if served["hash"] == @genesis.hash

        raise Client::Error,
              "this checkout's genesis is #{@genesis.hash[0, 12]} but the server is running " \
              "#{served['hash'].to_s[0, 12]}; the bot would acknowledge records nobody else has"
      end

      def safe_links
        return [] unless @persona.kind.posts_links?

        @categories.safe_links(origin: @client.origin)
      end

      # --- account ----------------------------------------------------------

      def ensure_account!
        return if @state.seed && @state.pubkey

        start_account(reason: "no account yet")
      end

      # The spam simulation: post for a few days, walk away from the account,
      # come back as somebody new. Whatever reputation the network built up
      # about the old key is still perfectly correct and no longer relevant to
      # anybody, which is the failure mode worth being able to watch.
      def recycle_if_due!
        return unless @state.expired?(now: now, speed: @speed)

        log "retiring #{@state.pubkey[0, 8]} after " \
            "#{format('%.1f', @state.age_days(now: now) * @speed)} days"
        start_account(reason: "recycled")
      end

      def start_account(reason:)
        phrase   = Identity.generate_phrase
        lifetime = @persona.lifetime_days(random: @random)
        identity = build_identity(phrase)
        username = @persona.username_for(@state.generation, random: @random)

        @state.recycle!(seed: phrase, pubkey: identity.pubkey, username: username,
                        category: @persona.category, retire_after_days: lifetime, now: now)
        @state.save
        @identity = identity

        life = lifetime ? format(", retiring in %.1f days", lifetime) : ""
        log "new account #{identity.pubkey[0, 8]} as #{username} (#{reason})#{life}"
      end

      def identity
        @identity ||= build_identity(@state.seed)
      end

      def build_identity(phrase)
        Identity.new(phrase: phrase, seed_config: @defaults.fetch("seed"))
      end

      # --- a visit ----------------------------------------------------------

      def visit
        session = @client.log_in(identity)
        fresh   = !session["registered"]
        @client.register if fresh

        view = build_view
        view.arrive!

        if fresh || view.revision.zero?
          establish(view)
          introduce!
          # The ratings just published are what this bot can see through, and
          # the session was sorted before they existed.
          view.arrive!
        end

        linger(view)
        consider_friending(view)
        @state.save
      rescue Client::Unauthorized => e
        # A session that will not open is not something to retry in a tight
        # loop; the next visit is hours away and will try again from scratch.
        log "login failed: #{e.message}"
      end

      def build_view
        View.new(client: @client, identity: identity, persona: @persona,
                 defaults: @defaults, genesis_hash: @genesis.hash)
      end

      # A new account arrives with contacts, the way a person who joined a
      # small server on somebody's recommendation does. The genesis account
      # always, because that is the one name everybody here knows; a couple of
      # other bots, because a network where nobody knows anybody but the
      # operator is not a network.
      def establish(view)
        view.set_profile(username: @state.username || @persona.username, bio: @persona.bio)
        view.adjust_rating(@genesis.pubkey, friend: true)

        friends = starting_friends
        friends.each { |member| view.adjust_rating(member.pubkey, friend: true) }

        view.publish_config!
        @state.revision = view.revision
        @state.save

        named = friends.map { |m| m.username || m.name }.join(", ")
        log "published profile as #{@state.username}; friended the genesis account" \
            "#{friends.empty? ? '' : " and #{named}"}"
      end

      def starting_friends
        roster = Roster.read(@state_dir, except: identity.pubkey)
        return [] if roster.empty?

        wanted = poisson(@persona.starting_friends)
        chosen = []
        while chosen.size < wanted && chosen.size < roster.size
          pick = Roster.preferred(roster - chosen, @persona.kind, random: @random)
          break unless pick

          chosen << pick
        end

        chosen
      end

      # An unrated account is invisible to everyone, so without this a bot
      # posts into a room where nobody can see it -- including the other bots,
      # which would leave the whole swarm talking to itself in separate silos.
      def introduce!
        return log("no vouchers configured; this account stays invisible") if @vouchers.nil? || @vouchers.empty?

        voucher = @vouchers.sample(random: @random)
        result  = @vouchers.introduce(
          voucher: voucher, target: identity.pubkey, client: @client.fork,
          seed_config: @defaults.fetch("seed"), defaults: @defaults
        )

        log "introduced by #{voucher.username} (#{result})"
      rescue Client::Error, Vouchers::Empty => e
        log "could not be introduced: #{e.message}"
      end

      # Counted in scheduled seconds rather than read off the clock, so that
      # compressing time cannot quietly change how many actions fit in a
      # visit. Between actions the bot is watching the room, which is what
      # most of being present consists of.
      def linger(view)
        length    = @schedule.visit_seconds
        remaining = length
        until_act = @schedule.gap_seconds
        @roster   = Roster.read(@state_dir).to_h { |m| [m.pubkey, m.category] }
        mark_seen(view)

        while remaining.positive?
          # Floored so the loop always moves: a persona with no gap floor and
          # a tiny mode can draw a gap of nearly zero, and a zero step would
          # act forever without the visit ever running out.
          step = [[@persona.poll_seconds, until_act, remaining].min, 0.5].max
          @sleep.call(step / @speed)
          remaining -= step
          until_act -= step

          view.refresh_room
          mark_seen(view)

          next if until_act.positive?

          act(view)
          until_act = @schedule.gap_seconds
        end

        log "left after #{format('%.1f', length / 60.0)} min"
      end

      def act(view)
        case @schedule.next_action
        when :post  then post(view)
        when :react then react(view)
        end
      end

      # --- actions ----------------------------------------------------------

      def post(view)
        reply_to = reply_target(view)
        body     = compose(view, reply_to)
        return unless body

        send_post(view, body, reply_to)
      rescue Client::Conflict => e
        # The server enforces one message per (author, seq). A collision means
        # this account's counter is behind what it has already published --
        # another copy of the same bot, or a state file restored from a
        # backup. Skipping ahead is the only way back into line.
        log "seq #{@state.seq} rejected (#{e.message}); skipping ahead"
        @state.seq += 1
        @state.save
      end

      def send_post(view, body, reply_to)
        # The server is the authority on what this account has already used.
        # A state file restored from a backup, or lost entirely, would
        # otherwise collide with its own history on every post.
        @state.seq = [@state.seq, view.highest_seq_for(identity.pubkey)].max
        seq        = @state.seq + 1

        record = @client.send_message(
          identity: identity, room: @persona.room, seq: seq, prev: @state.prev,
          body: body, ack: view.ack, reply_to: reply_to&.hash
        )

        @state.seq  = seq
        @state.prev = record
        @state.save

        log "#{reply_to ? 'replied' : 'posted'}: #{body[0, 90]}"

        # Replying counts as a vote, once per message, the same as reacting --
        # the browser treats them as the same act of approval.
        count_vote(view, reply_to, 1) if reply_to
      end

      def react(view)
        target = pick(view.visible_from_others.reject { |m| @state.voted?(m.hash) })
        return unless target

        emote = pick_emote
        @client.send_emote(identity: identity, room: @persona.room,
                           message: target.hash, emote: emote, ack: view.ack)

        log "reacted #{emote} to #{view.display_name(target.author)}: #{target.body[0, 60]}"
        count_vote(view, target, polarity(emote))
      rescue Client::Conflict
        # Already reacted to that message in a previous life of this state
        # file. Remember it so it is not picked again.
        @state.vote(target.hash)
        @state.save
      end

      # A reaction that never reaches the reacting bot's config changes
      # nobody's reputation: the records are the display form, the config is
      # the reputation form.
      def count_vote(view, message, polarity)
        return if message.nil? || message.author == identity.pubkey
        return if @state.voted?(message.hash)

        @state.vote(message.hash)
        view.adjust_rating(message.author, votes: polarity)
        view.publish_config!
        @state.revision = view.revision
        @state.save
      end

      # Rare, and only for somebody this bot has already been positive about.
      # Friending is worth 0.5 on its own, which is most of the way to Trusted
      # for anyone it reaches -- a bot that handed them out freely would make
      # the whole graph trusted within a day.
      #
      # A gullible account is the exception the categories exist to express:
      # it vouches for exactly the people it should not, which is what makes
      # its own standing worth watching.
      def consider_friending(view)
        return unless @random.rand < @persona.friend_per_visit

        candidates = view.ratings.reject do |pubkey, rating|
          rating["friend"] || !rating.fetch("net_votes", 0).positive? || pubkey == identity.pubkey
        end
        return if candidates.empty?

        chosen = prefer_drawn(candidates.keys)
        view.adjust_rating(chosen, friend: true)
        view.publish_config!
        @state.revision = view.revision
        @state.save

        log "friended #{view.display_name(chosen)}"
      end

      # --- choosing ---------------------------------------------------------

      def compose(view, reply_to)
        context = Brain::Context.new(
          kind: reply_to ? :reply : :post,
          target: reply_to,
          target_name: reply_to && view.display_name(reply_to.author),
          recent: transcript(view),
          name: @state.username || @persona.username,
          room: @persona.room
        )

        @brain.compose(context)
      end

      # What the model is shown: the tail of what this account can actually
      # see. A bot that is blocked from seeing somebody should not be writing
      # replies informed by them either.
      def transcript(view, limit: 12)
        view.visible_messages.last(limit).map { |m| [view.display_name(m.author), m.body] }
      end

      def reply_target(view)
        return nil unless @random.rand < @persona.reply_ratio

        pick(view.visible_from_others)
      end

      # Recency-weighted, after a pull towards whoever this category is drawn
      # to. People answer what is in front of them; a gullible account answers
      # whoever is offering it something.
      def pick(messages)
        return nil if messages.empty?

        pool    = attracted(messages) || messages
        weights = pool.each_index.map { |i| (i + 1.0)**2 }
        roll    = @random.rand * weights.sum
        running = 0.0

        pool.zip(weights).find { |_, weight| (running += weight) > roll }&.first || pool.last
      end

      def attracted(messages)
        return nil if @persona.kind.drawn_to.empty? || @random.rand >= ATTRACTION

        drawn = messages.select { |m| drawn_to?(m.author) }
        drawn.empty? ? nil : drawn
      end

      def prefer_drawn(pubkeys)
        drawn = pubkeys.select { |pubkey| drawn_to?(pubkey) }

        (drawn.any? && @random.rand < ATTRACTION ? drawn : pubkeys).sample(random: @random)
      end

      def drawn_to?(pubkey)
        @persona.kind.drawn_to.include?((@roster || {})[pubkey])
      end

      def pick_emote
        pools = @persona.emote_bias.filter_map do |category, weight|
          options = @emotes[category]
          [category, Float(weight)] if options&.any? && Float(weight).positive?
        end
        return @emotes.fetch("positive").sample(random: @random) if pools.empty?

        roll    = @random.rand * pools.sum(&:last)
        running = 0.0
        chosen  = pools.find { |_, weight| (running += weight) > roll }&.first || pools.first.first

        @emotes.fetch(chosen).sample(random: @random)
      end

      def polarity(emote)
        return -1 if @emotes.fetch("negative", []).include?(emote)
        return 0 if @emotes.fetch("neutral", []).include?(emote)

        1
      end

      def mark_seen(view)
        view.visible_messages.each { |m| @state.see(m.hash) }
      end

      # --- plumbing ---------------------------------------------------------

      def now = Time.now.to_i

      # Knuth's, which is exact for the small means a starting friend list
      # uses and needs no tables.
      def poisson(mean)
        return 0 unless mean.positive?

        limit = Math.exp(-mean)
        count = 0
        product = 1.0

        loop do
          product *= @random.rand
          break if product <= limit

          count += 1
        end

        count
      end

      def wait(seconds, what)
        log "#{what} in #{human(seconds.round)}"
        @sleep.call(seconds / @speed)
      end

      def human(seconds)
        return "#{seconds}s" if seconds < 90
        return "#{(seconds / 60.0).round}m" if seconds < 5400

        format("%.1fh", seconds / 3600.0)
      end

      def log(message) = @log.call("#{@name}: #{message}")
    end
  end
end
