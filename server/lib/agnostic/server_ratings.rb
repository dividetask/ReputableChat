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
  # The operator can set any account's rating by hand, trust included (rake
  # rate); that stands in for the rating above until it is removed (rake
  # unrate), and is published the same way.
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

    # What this server says of each account it has an opinion of: an
    # operator's rating where there is one, else what reachability says.
    def current
      contacts = @store.contacts.to_h { |c| [c[:account], c] }
      overrides = @store.rating_overrides.to_h { |o| [o[:account], o] }
      (contacts.keys | overrides.keys).each_with_object({}) do |account, out|
        next if account == @host.id

        if (o = overrides[account])
          out[account] = { "reputation" => o[:reputation], "trust" => o[:trust], "source" => "operator" }
        elsif (rating = contacts[account] && rating_for(contacts[account]))
          out[account] = { "reputation" => rating, "trust" => trust, "source" => "reachability" }
        end
      end
    end

    # What has changed since the last attestation. An account whose rating
    # was published and which this server no longer has an opinion of -- an
    # operator's rating removed with nothing to fall back on -- is published
    # as 0 with trust 0, since an attestation can amend an entry but not
    # delete one.
    def due
      now = current
      changed = now.each_with_object({}) do |(account, score), out|
        published = @store.published_rating(account)
        next if published && published[:reputation] == score["reputation"] && published[:trust] == score["trust"]

        out[account] = score.slice("reputation", "trust")
      end
      @store.published_ratings.each do |row|
        next if now.key?(row[:account]) || (row[:reputation] == "0" && row[:trust] == "0")

        changed[row[:account]] = { "reputation" => "0", "trust" => "0" }
      end
      changed
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

    # Always 0. This server judges only whether another server stays online,
    # and saying a server reliably produces heartbeats must not read as
    # saying its ratings are worth believing.
    TRUST = "0"

    def trust = TRUST

    # A rating as the rules spell a decimal, held between -1 and +1.
    def setting(*keys)
      value = @settings.decimal("ratings", *keys, minimum: -1)
      Formats.write([value, BigDecimal("1")].min)
    end
  end
end
