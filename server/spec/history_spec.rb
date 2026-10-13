# frozen_string_literal: true

require_relative "spec_helper"

# A record's history is answered from the walk back to the nearest
# heartbeats and the generations behind them, not by listing it. It must be
# exactly the history listed in full -- everything the acks reach -- or the
# server accepts records the rules refuse, or refuses valid ones, and every
# signature still verifies.
class HistorySpec < Minitest::Test
  include ChainHelpers

  def setup
    setup_chain
    @bob = declare("bob").digest
    @carol = declare("carol", ack: [@bob]).digest
    @beats = { "bob" => [], "carol" => [] }
  end

  def account(name) = { "bob" => @bob, "carol" => @carol }.fetch(name)

  def beat(name, ack: [])
    previous = @beats[name].last
    ack = (ack + [previous&.digest || account(name)]).uniq
    @now += 480
    @beats[name] << accept(post(name, account(name), ack: ack, ts: @now, type: "reputablechat:heartbeat:#{version}"))
    @beats[name].last
  end

  def note(name, ack:, body: "") = accept(post(name, account(name), ack: (ack + [account(name)]).uniq, body: body, ts: @now += 1))

  def stored = @store.db[:records].order(:seq).select_map(:hash)

  # Every stored record's history, every way it is asked, against the
  # history listed in full.
  def assert_histories_are_exact
    all = stored
    authors = @store.heartbeat_authors
    all.each do |hash|
      expected = @store.closure([hash]).tap { |set| set.delete(hash) }
      history = Agnostic::Histories.new(@store).of(hash)
      assert_equal expected & all.to_set, history.among(all), "#{hash[0, 8]}'s history"
      authors.each do |author|
        newest = @store.db[:records].where(hash: expected.to_a, account: author, kind: "heartbeat").max(:beat_index)
        message = "#{hash[0, 8]}'s newest heartbeat of #{author[0, 8]}"
        newest ? assert_equal(newest, history.newest_beat(author), message) : assert_nil(history.newest_beat(author), message)
      end
    end
  end

  def test_the_example_chain_has_the_same_histories_listed_or_not
    load_examples
    assert_histories_are_exact
  end

  # Two publishers beating across each other, records left behind and joined
  # late, and one publisher's line forking: past the fork the history is
  # listed in full, and must agree all the same.
  def test_histories_across_heartbeats_and_a_fork_are_the_same_listed_or_not
    left = note("carol", ack: [@carol], body: "left behind")
    6.times do |i|
      beat("bob", ack: i.even? ? [@beats["carol"].last&.digest].compact : [])
      note("carol", ack: [@beats["bob"].last.digest], body: "after #{i}")
      beat("carol", ack: [@beats["bob"].last.digest])
    end
    joined = note("bob", ack: [left.digest, @beats["carol"].last.digest], body: "joined late")

    base = @beats["bob"].last
    @beats["bob"] << beat("bob", ack: [joined.digest])
    @beats["bob"].pop
    twin = accept(post("bob", @bob, ack: [base.digest], ts: @now += 480, type: "reputablechat:heartbeat:#{version}"))
    @beats["bob"] << twin
    3.times { beat("bob") }
    note("carol", ack: [twin.digest, @beats["bob"].last.digest], body: "holds both branches")

    refute_equal Float::INFINITY, @store.first_fork(@bob), "the line forked"
    assert_histories_are_exact
  end
end
