# frozen_string_literal: true

require_relative "../reputation/rating"

module ReputableChat
  module Store
    # In-memory rating graph. Backs the tests, and stands in for the batch
    # fetch the client will use against the server.
    class Memory
      def initialize
        @ratings = Hash.new { |h, k| h[k] = {} }
      end

      def rate(rater, subject, friend: false, reported: false, net_votes: 0)
        @ratings[rater][subject] = Reputation::Rating.new(
          friend: friend, reported: reported, net_votes: net_votes
        )
        self
      end

      def friend(rater, subject) = rate(rater, subject, friend: true)
      def report(rater, subject) = rate(rater, subject, reported: true)
      def like(rater, subject, count) = rate(rater, subject, net_votes: count)

      # Builds a gated path viewer -> a -> b -> ... by friending each link.
      def chain(*people)
        people.each_cons(2) { |from, to| friend(from, to) }
        self
      end

      # Store an existing Rating as-is. Used when snapshotting a graph.
      def put(rater, subject, rating)
        @ratings[rater][subject] = rating
        self
      end

      def ratings_by(pubkey) = @ratings[pubkey]
      def rating(pubkey, subject) = @ratings[pubkey][subject]
    end
  end
end
