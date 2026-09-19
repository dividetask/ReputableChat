# frozen_string_literal: true

require "json"

module ReputableChat
  module Bot
    # The other bots this operator is running, read off the state directory.
    #
    # Bots are meant to know each other the way people who joined the same
    # small server do -- a new account arrives with one or two contacts, not
    # with nobody. Reading it off disk keeps that to bots on this machine,
    # which is where a test swarm lives.
    module Roster
      Member = Struct.new(:name, :pubkey, :username, :category, keyword_init: true)

      module_function

      def read(dir, except: nil)
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.json")).filter_map do |path|
          next if File.basename(path) == "vouchers.json"

          member = parse(path)
          next if member.nil? || member.pubkey == except

          member
        end
      end

      # Who a bot of this category gravitates towards, from
      # config/bot-categories.yml. A gullible account friending scammers is the
      # behaviour under test, so it is arranged rather than hoped for: no 270M
      # model is going to work out who is worth trusting.
      def preferred(members, category, random: Random.new)
        drawn = members.select { |m| category.drawn_to.include?(m.category) }

        (drawn.any? && random.rand < 0.75 ? drawn : members).sample(random: random)
      end

      def parse(path)
        data = JSON.parse(File.read(path))
        return nil if data["pubkey"].to_s.empty?

        Member.new(name: data["name"], pubkey: data["pubkey"],
                   username: data["username"], category: data["category"])
      rescue JSON::ParserError
        nil
      end
    end
  end
end
