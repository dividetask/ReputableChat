# frozen_string_literal: true

require_relative "../brain"

module ReputableChat
  module Bot
    module Brain
      # A list of lines, picked at random. This is the spam bot: it does not
      # read the room, because a real one does not either.
      #
      # It costs nothing to run, which matters when the point of the exercise
      # is fifty of them at once.
      class Scripted
        def initialize(persona:, random: Random.new, links: [])
          @lines  = persona.lines
          @random = random
          @links  = links
          @recent = []
        end

        # Its lines go through the same cleanup a model's output does, so a
        # link written into a persona file is replaced with a safe one rather
        # than trusted because a person typed it.
        def compose(_context)
          Brain.clean(pick, links: @links, random: @random)
        end

        private

        # Avoids repeating the last few lines, so a bot with eight lines does
        # not post the same one twice running and read as obviously canned.
        def pick
          window = [@lines.size / 2, @lines.size - 1].min
          choices = @lines.reject { |line| @recent.include?(line) }
          choices = @lines if choices.empty?

          chosen  = choices.sample(random: @random)
          @recent = (@recent + [chosen]).last(window)

          chosen
        end
      end
    end
  end
end
