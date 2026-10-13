# frozen_string_literal: true

require "bigdecimal"
require_relative "formats"

module Agnostic
  # Ratings this server publishes of other servers, from nothing but whether it
  # could reach them at the addresses their accounts declared.
  #
  # - Never reached, then forgotten: the declared address never worked.
  #   ratings.never_reached (-1).
  # - Reached for a while, then forgotten: ratings.went_offline (-0.01).
  # - Reached at least ratings.reliable_ratio of the times it was tried:
  #   ratings.reliable.rating once ratings.reliable.after_seconds (about four
  #   months) have passed since it was first reached, and
  #   ratings.established.rating once ratings.established.after_seconds (a
  #   year) have.
  # - Anything else: no opinion, and nothing is published.
  #
  # Each app beside the server can move an account's rating by its own
  # judgement (POST /api/nudges, on the local listener): reputation and
  # trust, one nudge per app and account. What is published is this
  # server's own rating -- 0 where it has none -- plus every app's
  # nudge, reputation and trust each summed and held between -1 and +1.
  #
  # The operator can set any account's rating by hand, trust included (rake
  # rate); that overrides everything above, nudges included, until it is
  # removed (rake unrate), and is published the same way.
  #
  # An account this server publishes a rating of -1 for, however it came to
  # -1, is ignored -- no contact either way -- for as long as that is what it
  # publishes: until an administrator forgives it (rake forgive), or a later
  # rating above -1 is published, as when an app takes its nudge back or
  # another app nudges it up. A server ignored for its clock stays ignored
  # for its own reasons. Every other server can come back by itself.
  #
  # It is published as an attestation of the host account, holding only the
  # ratings that changed since the last one -- a later attestation amends the
  # earlier ones rather than replacing them -- so one is rare: a server's
  # rating moves at most a few times in its life.
  class ServerRatings
    RATED_OUT = "this server rated it -1"

    def initialize(store:, ingest:, host:, settings:, clock: -> { Time.now.to_i })
      @store = store
      @ingest = ingest
      @host = host
      @settings = settings
      @clock = clock
    end

    # What this server says of each account it has an opinion of, and where
    # it came from: "operator", "reachability" and "nudges" (by app),
    # each present only when there is one. The operator's rating, when set,
    # is what is said; otherwise reachability plus the nudges.
    def current
      contacts = @store.contacts.to_h { |c| [c[:account], c] }
      overrides = @store.rating_overrides.to_h { |o| [o[:account], o] }
      nudges = @store.nudges.group_by { |a| a[:account] }
      (contacts.keys | overrides.keys | nudges.keys).each_with_object({}) do |account, out|
        next if account == @host.id

        parts = {}
        reachable = contacts[account] && rating_for(contacts[account])
        parts["reachability"] = { "reputation" => reachable, "trust" => trust } if reachable
        if nudges[account]
          parts["nudges"] = nudges[account].to_h { |a| [a[:app], { "reputation" => a[:reputation], "trust" => a[:trust] }] }
        end
        if (o = overrides[account])
          parts["operator"] = { "reputation" => o[:reputation], "trust" => o[:trust] }
          out[account] = parts["operator"].merge(parts)
        elsif parts.any?
          out[account] = combined(parts).merge(parts)
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
          if score["reputation"] == "-1"
            @store.ignore(account, reason: RATED_OUT, at: @clock.call, until_at: Store::FOREVER)
          else
            @store.forgive(account, reason: RATED_OUT)
          end
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

    def combined(parts)
      shares = [parts["reachability"], *parts.fetch("nudges", {}).values].compact
      %w[reputation trust].to_h do |key|
        sum = shares.sum(BigDecimal("0")) { |share| Formats.decimal(share[key]) }
        [key, Formats.write(sum.clamp(BigDecimal("-1"), BigDecimal("1")))]
      end
    end

    def reliable?(contact)
      ratio = @settings.decimal("ratings", "reliable_ratio", minimum: 0)
      BigDecimal(contact[:successes]) >= ratio * contact[:attempts]
    end

    # Always 0 for reachability. This server judges only whether another
    # server stays online, and saying a server reliably produces heartbeats
    # must not read as saying its ratings are worth believing. Apps, which
    # know more, may move trust by their nudges.
    TRUST = "0"

    def trust = TRUST

    # A rating as the rules spell a decimal, held between -1 and +1.
    def setting(*keys)
      value = @settings.decimal("ratings", *keys, minimum: -1)
      Formats.write([value, BigDecimal("1")].min)
    end
  end
end
