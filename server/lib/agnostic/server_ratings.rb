# frozen_string_literal: true

require "bigdecimal"
require_relative "formats"

module Agnostic
  # Ratings this server publishes of other servers, from nothing but whether it
  # could reach them at the addresses their accounts declared.
  #
  # - Never reached, then forgotten: the declared address never worked.
  #   ratings.never_reached (-1).
  # - Reached for a while, then forgotten: ratings.went_offline (0).
  # - Reached at least ratings.reliable_ratio of the times it was tried:
  #   ratings.reliable.rating once ratings.reliable.after_seconds (about four
  #   months) have passed since it was first reached, and
  #   ratings.established.rating once ratings.established.after_seconds (a
  #   year) have.
  # - Anything else: no opinion, and nothing is published.
  #
  # It is published as an attestation of the host account, holding only the
  # ratings that changed since the last one -- a later attestation amends the
  # earlier ones rather than replacing them -- so one is rare: a server's
  # rating moves at most a few times in its life.
  class ServerRatings
    def initialize(store:, ingest:, host:, settings:, clock: -> { Time.now.to_i })
      @store = store
      @ingest = ingest
      @host = host
      @settings = settings
      @clock = clock
    end

    # What this server should say of each server account it has tried.
    def due
      @store.contacts.each_with_object({}) do |contact, out|
        next if contact[:account] == @host.id

        rating = rating_for(contact)
        next unless rating

        published = @store.published_rating(contact[:account])
        next if published && published[:reputation] == rating && published[:trust] == trust

        out[contact[:account]] = { "reputation" => rating, "trust" => trust }
      end
    end

    # Publishes an attestation when any rating changed. Returns the Ingest
    # result, or nil when there was nothing to say.
    def publish
      scores = due
      return if scores.empty?

      latest = @store.by_account(@host.id).max_by(&:seq)
      record = @host.sign("attestation", { "ack" => [latest.digest], "body" => "", "scores" => scores,
                                           "ts" => @clock.call })
      result = @ingest.submit(record)
      if result.status == :accepted
        scores.each do |account, score|
          @store.save_published_rating(account, reputation: score["reputation"], trust: score["trust"], at: @clock.call)
        end
      end
      result
    end

    def rating_for(contact)
      if contact[:offline]
        return setting("never_reached") unless contact[:first_success_at]

        return setting("went_offline")
      end
      return unless contact[:first_success_at] && reliable?(contact)

      age = @clock.call - contact[:first_success_at]
      if age >= @settings.integer("ratings", "established", "after_seconds")
        setting("established", "rating")
      elsif age >= @settings.integer("ratings", "reliable", "after_seconds")
        setting("reliable", "rating")
      end
    end

    private

    def reliable?(contact)
      ratio = @settings.decimal("ratings", "reliable_ratio", minimum: 0)
      BigDecimal(contact[:successes]) >= ratio * contact[:attempts]
    end

    def trust = setting("trust")

    # A rating as the rules spell a decimal, held between -1 and +1.
    def setting(*keys)
      value = @settings.decimal("ratings", *keys, minimum: -1)
      Formats.write([value, BigDecimal("1")].min)
    end
  end
end
