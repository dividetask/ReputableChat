# frozen_string_literal: true

require "bigdecimal"
require_relative "reputation/decimals"

module ReputableChat
  # The chat's own judgement of other chat servers, passed to its agnostic
  # server as a nudge: a move to the rating it publishes of the server's
  # account, added to the server's own (reachability) and every other app's.
  #
  # Each attempt to fetch a file from another chat server (FilePeers) scores
  # 1 when it was reached, 1 - missing_penalty when it answered without the
  # file, and 0 when it did not answer. Over the last WINDOW the scores
  # average to a share, and the nudge is
  #
  #   step * (2 * average - 1)
  #
  # +step for a server that always has what it is asked for, -step for one
  # that never answers, and nothing with no attempts in the window. Trust is
  # left at 0. A nudge is sent rounded to three decimals, and only when that
  # differs from the last one sent; "0" takes it back.
  class Nudges
    APP = "chat"
    WINDOW = 30 * 86_400
    SCALE = 3
    SCORES = { reached: BigDecimal("1"), unreached: BigDecimal("0") }.freeze

    def initialize(store:, chain:, step:, missing_penalty:, clock: -> { Time.now.to_i })
      @store = store
      @chain = chain
      @step = BigDecimal(step.to_s)
      @missing_score = BigDecimal("1") - BigDecimal(missing_penalty.to_s)
      @clock = clock
      @lock = Mutex.new
    end

    # Records how a fetch from account went, and sends whatever nudges that
    # changed: this account's, and any whose attempts have all aged out.
    def record(account, outcome)
      now = @clock.call
      @lock.synchronize do
        @store.record_fetch(account, outcome, at: now)
        @store.forget_fetches_before(now - WINDOW)
        stale = @store.nudges_sent.reject { |_, sent| sent["reputation"] == "0" }.keys
        ([account] | stale).each { |each| send_if_changed(each, now) }
      end
    end

    # The nudge for an account now, spelled as the rules spell a decimal.
    def reputation(account, now = @clock.call)
      scores = @store.fetches_since(account, now - WINDOW).map { |o| SCORES.fetch(o) { @missing_score } }
      return "0" if scores.empty?

      average = scores.sum / scores.size
      Reputation.decimal(@step * ((2 * average) - 1), SCALE)
    end

    private

    # Best effort: a nudge that does not arrive is sent with the next one.
    def send_if_changed(account, now)
      value = reputation(account, now)
      sent = @store.nudges_sent[account]
      return if sent ? sent["reputation"] == value : value == "0"

      @chain.nudge(app: APP, account: account, reputation: value, trust: "0")
      @store.save_nudge_sent(account, reputation: value, trust: "0")
    rescue StandardError
      nil
    end
  end
end
