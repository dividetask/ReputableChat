# frozen_string_literal: true

require_relative "../brain"

module ReputableChat
  module Bot
    module Brain
      # An order-2 Markov chain over what this account has actually read.
      #
      # The middle tier: it needs no model and no network, and it produces
      # something that is on-topic in vocabulary and nonsense in meaning --
      # which is a fair imitation of a low-effort account, and a useful
      # baseline for judging whether the LLM bots are worth their memory.
      class Markov
        START = :start
        STOP  = :stop

        # Below this the chain just parrots its input, so it stays quiet and
        # falls back to the seed lines until it has read enough.
        MIN_SAMPLES = 20

        def initialize(persona:, random: Random.new, links: [])
          @random  = random
          @links   = links
          @chain   = Hash.new { |h, k| h[k] = [] }
          @samples = 0
          @seeds   = persona.lines
          @seen    = {}

          persona.lines.each { |line| learn(line) }
        end

        def compose(context)
          context.recent.each { |(_, body)| observe(body) }

          if @samples < MIN_SAMPLES
            return Brain.clean(@seeds.sample(random: @random), links: @links, random: @random)
          end

          Brain.clean(generate, name: context.name, links: @links, random: @random)
        end

        # Each message is learned once, however many times it is seen in the
        # room's backlog -- otherwise a long-lived bot weights whatever has sat
        # at the top of the last 100 for days.
        def observe(body)
          key = body.hash
          return if @seen.key?(key)

          @seen[key] = true
          learn(body)
        end

        private

        def learn(body)
          words = body.to_s.split(/\s+/).reject(&:empty?)
          return if words.size < 3

          @samples += 1
          previous = [START, START]

          words.each do |word|
            @chain[previous] << word
            previous = [previous[1], word]
          end
          @chain[previous] << STOP
        end

        def generate
          previous = [START, START]
          words    = []

          while words.size < 40
            choices = @chain[previous]
            break if choices.empty?

            word = choices.sample(random: @random)
            break if word == STOP

            words << word
            previous = [previous[1], word]
          end

          words.join(" ")
        end
      end
    end
  end
end
