# frozen_string_literal: true

module ReputableChat
  module Bot
    # Where a bot's words come from. Three of them, cheapest first: a fixed
    # list of lines, a Markov chain over what it has read, and a small local
    # model. They answer the same call, so a swarm can mix all three and the
    # script runs with no model installed at all.
    module Brain
      # What the brain is being asked for. `recent` is oldest-last, already
      # filtered to what this account can see.
      Context = Struct.new(:kind, :target, :target_name, :recent, :name, :room,
                           keyword_init: true)

      # Chat length, not the server's 4000-byte limit. A tiny model asked for
      # "a short line" will sometimes write an essay, and an essay in a chat
      # room reads as broken rather than as a bot.
      MAX_CHARS = 280

      # A leading "Sam:" or "Assistant:" is the most common thing a small
      # instruct model adds unasked. Only ever stripped for the speaker's own
      # name or one of these, never for any word before a colon -- "URGENT:
      # your account will be suspended" is a message, not a prefix.
      ARTIFACT_PREFIX = /\A(assistant|ai|bot|system|response|answer|reply|output|user)\s*:\s*/i
      CONTROL         = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

      # Anything that could be clicked. Deliberately greedy: a false positive
      # costs a bot one hallucinated URL, a false negative puts a link nobody
      # vetted in front of whoever is testing the server.
      URL = %r{
        \b(?:https?://|www\.)\S+
        |
        \b[a-z0-9](?:[a-z0-9-]*[a-z0-9])?
         \.(?:com|net|org|io|co|ly|xyz|link|click|info|biz|app|shop|top|ru|tk|gg|me)
         \b(?:/\S*)?
      }ix

      module_function

      # `links` is what this bot may post, already resolved: the category's
      # safe list, or empty for a category that posts none.
      def for(persona, random: Random.new, links: [], logger: nil)
        options = { persona: persona, random: random, links: links }

        case persona.brain
        when "scripted" then Scripted.new(**options)
        when "markov"   then Markov.new(**options)
        when "llm"      then Llm.new(**options, logger: logger)
        else raise ArgumentError, "unknown brain #{persona.brain.inspect}"
        end
      end

      # Turns whatever came back into something the server will accept, or nil.
      #
      # Nil is a normal outcome, not an error: a bot that produced nothing
      # usable just read the room instead, which is what a person who started
      # typing and thought better of it does.
      # `links` is the category's link policy, already resolved to absolute
      # URLs. Empty or absent strips every URL; a list replaces each one.
      # There is no option that lets a link through: a model inventing a
      # domain, or a persona's scripted line smuggling one, is not a risk
      # worth carrying for a test harness.
      def clean(text, name: nil, links: nil, random: Random.new)
        line = text.to_s.gsub(CONTROL, " ")
        line = substitute_links(line, links, random)
        line = line.gsub(/\s+/, " ").strip
        line = line.sub(ARTIFACT_PREFIX, "")
        line = line.sub(/\A#{Regexp.escape(name)}\s*:\s*/i, "") if name
        line = line[1...-1].to_s.strip if line.match?(/\A(["'])(?!.*\1.*\1).*\1\z/m)
        line = truncate(line)

        line.empty? ? nil : line
      end

      def substitute_links(line, links, random)
        safe = Array(links)

        line.gsub(URL) { safe.empty? ? " " : safe.sample(random: random) }
      end

      # On a word boundary where there is one, so a cut-off message looks like
      # someone who stopped typing rather than like a truncated buffer.
      def truncate(line)
        return line if line.length <= MAX_CHARS

        cut = line[0, MAX_CHARS]
        space = cut.rindex(" ")

        (space && space > MAX_CHARS / 2 ? cut[0, space] : cut).strip
      end
    end
  end
end
