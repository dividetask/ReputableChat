# frozen_string_literal: true

require "yaml"

module ReputableChat
  module Bot
    # The seven things a bot can be pretending to be, loaded from
    # config/bot-categories.yml.
    #
    # `definition` and `guidance` go to the model verbatim. `drawn_to` and
    # `links` are acted on by the script instead, because a small model cannot
    # be relied on to follow an instruction it was given hundreds of tokens
    # ago -- and because "never post a real link" has to be true rather than
    # requested.
    class Categories
      PATH = File.expand_path("../../../config/bot-categories.yml", __dir__)

      class Unknown < StandardError; end
      class Malformed < StandardError; end

      Category = Struct.new(:name, :definition, :guidance, :drawn_to, :links,
                            keyword_init: true) do
        # What the model is told it is, above the persona's own disposition.
        def briefing
          ["#{name}: #{definition.strip}", guidance.strip].reject(&:empty?).join("\n\n")
        end

        def posts_links? = links == "safe"
      end

      LINK_POLICIES = %w[none safe].freeze

      attr_reader :names

      def self.load(path: PATH)
        raw = YAML.safe_load_file(path)
        raise Malformed, "#{path} has no `categories` mapping" unless raw.is_a?(Hash) && raw["categories"]

        new(raw, path: path)
      end

      def self.current = @current ||= load

      def initialize(raw, path: PATH)
        @path       = path
        @safe_links = Array(raw["safe_links"]).map(&:to_s).reject(&:empty?)
        @categories = raw.fetch("categories").to_h do |name, body|
          [name.to_s, build(name.to_s, body)]
        end
        @names = @categories.keys.freeze

        raise Malformed, "#{path} lists no categories" if @categories.empty?
      end

      def fetch(name)
        @categories[name.to_s] or
          raise Unknown, "unknown category #{name.inspect}; known ones are #{@names.join(', ')}"
      end

      def known?(name) = @categories.key?(name.to_s)

      # Relative entries are resolved against the server, so the landing page
      # is served by the same origin the bots are posting to rather than being
      # a dead link on somebody else's machine.
      def safe_links(origin:)
        @safe_links.map { |link| link.start_with?("/") ? "#{origin.to_s.chomp('/')}#{link}" : link }
      end

      private

      def build(name, body)
        raise Malformed, "category #{name} is not a mapping" unless body.is_a?(Hash)

        policy = body.fetch("links", "none").to_s
        unless LINK_POLICIES.include?(policy)
          raise Malformed, "category #{name} has links: #{policy.inspect}; expected one of #{LINK_POLICIES.join(', ')}"
        end

        Category.new(
          name: name,
          definition: body["definition"].to_s,
          guidance: body["guidance"].to_s,
          drawn_to: Array(body["drawn_to"]).map(&:to_s),
          links: policy
        )
      end
    end
  end
end
