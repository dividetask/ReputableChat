# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_helper"

# The rules that need a record's history (docs/project/rules/v0.001.md), as
# Chain::Ledger enforces them. Each test names the rule it protects.
class LedgerSpec < Minitest::Test
  include ChainHelper

  def setup
    @tim, genesis = genesis_account
    @ledger = ReputableChat::Chain::Ledger.new(genesis: genesis)
    @genesis = genesis.record_hash
    @alice = Account.new
    @alice_decl = declare(@ledger, @alice, ack: [@genesis], handle: "Alice")
  end

  def say(account, ack:, key: account.working, body: "hi", ts: 2_000, **extra)
    publish(@ledger, Payload.message(id: account.id, pubkey: ChainHelper.key_of(key), body: body,
                                     ack: ack, ts: ts, **extra), key)
  end

  def refuses(pattern, &block)
    error = assert_raises(Invalid, &block)
    assert_match pattern, error.message
  end

  # --- acks and versions (sections 1, 2, 9) -------------------------------

  def test_a_record_cannot_acknowledge_what_the_server_does_not_hold
    error = assert_raises(ReputableChat::Chain::Ledger::Unknown) do
      say(@alice, ack: ["a" * 64])
    end
    assert_match(/send it first/, error.message)
  end

  def test_only_one_record_is_the_genesis
    other, = genesis_account
    second = signed(Payload.identity(pubkey: other.pubkey, handle: "Tom", ack: [], ts: 1, rules: "r"), other.working)

    refuses(/already a genesis/) { @ledger.add(second) }
  end

  def test_a_record_acknowledges_only_records_of_its_own_version
    payload = Payload.message(id: @alice.id, pubkey: @alice.pubkey, body: "hi", ack: [@alice_decl.record_hash], ts: 2)
    payload["type"] = "reputablechat:message:v0.002"

    refuses(/share this record's version/) { publish(@ledger, payload, @alice.working) }
  end

  def test_a_release_acknowledges_the_previous_version_and_starts_a_new_one
    release = Payload.release(id: @tim.id, pubkey: @tim.pubkey, version: "v0.002", rules: "new rules",
                              ack: [@alice_decl.record_hash], ts: 3)
    assert_equal :ok, @ledger.add(signed(release, @tim.working))

    same = Payload.release(id: @tim.id, pubkey: @tim.pubkey, version: "v0.001", rules: "again",
                           ack: [@alice_decl.record_hash], ts: 4)
    refuses(/new version/) { publish(@ledger, same, @tim.working) }
  end

  # A record of rules this code does not implement cannot be judged, so it is
  # refused rather than accepted on trust.
  def test_records_of_a_version_this_server_does_not_implement_are_refused
    release = publish(@ledger, Payload.release(id: @tim.id, pubkey: @tim.pubkey, version: "v0.002",
                                               rules: "new rules", ack: [@alice_decl.record_hash], ts: 3), @tim.working)
    payload = Payload.message(id: @tim.id, pubkey: @tim.pubkey, body: "hi", ack: [release.record_hash], ts: 4)
    payload["type"] = "reputablechat:message:v0.002"

    refuses(/implements rules v0.001/) { publish(@ledger, payload, @tim.working) }
  end

  def test_an_account_id_must_name_a_declaration_in_the_record_history
    bob = Account.new
    declare(@ledger, bob, ack: [@genesis])

    refuses(/names no account in this record's history/) do
      publish(@ledger, Payload.message(id: bob.id, pubkey: bob.pubkey, body: "x", ack: [@genesis], ts: 2), bob.working)
    end
  end

  def test_endorse_names_only_records_in_the_history
    other = say(@tim, ack: [@genesis])

    refuses(/not in this record's history/) do
      say(@alice, ack: [@alice_decl.record_hash], endorse: [other.record_hash])
    end
  end

  # --- keys (section 2) -----------------------------------------------------

  def test_a_record_must_be_signed_with_a_key_of_its_account
    refuses(/may not sign with/) { say(@alice, ack: [@alice_decl.record_hash], key: new_key) }
  end

  def key_change(account, to:, ack:, key: account.working, kind: "key-change", ts: 3_000)
    payload = Payload.notice(id: account.id, pubkey: ChainHelper.key_of(key), kind: kind,
                             body: ChainHelper.key_of(to), ack: ack, ts: ts)
    if key == account.master
      payload["mpubkey"] = payload.delete("pubkey")
    end
    publish(@ledger, payload, key)
  end

  def test_a_key_change_lets_the_new_key_sign
    replacement = new_key
    change = key_change(@alice, to: replacement, ack: [@alice_decl.record_hash])

    assert say(@alice, ack: [change.record_hash], key: replacement)
  end

  def test_a_master_key_change_is_signed_with_the_master_key
    refuses(/current master key/) do
      key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], kind: "master-key-change")
    end
    assert key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], kind: "master-key-change", key: @alice.master)
  end

  # RULE: signing with a key a change superseded contests the change and
  # disputes the account -- and the record is still valid.
  def test_signing_with_a_superseded_key_contests_the_change
    change = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash])
    contest = say(@alice, ack: [change.record_hash], key: @alice.working)

    assert_equal [change], contest.contests
    assert @ledger.disputed?(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)
  end

  def test_a_record_that_does_not_hold_the_change_contests_nothing
    key_change(@alice, to: new_key, ack: [@alice_decl.record_hash])
    elsewhere = say(@alice, ack: [@alice_decl.record_hash])

    assert_empty elsewhere.contests
  end

  # RULE: two concurrent changes of the same key conflict and dispute the account.
  def test_concurrent_key_changes_conflict
    key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_000)
    key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_001)

    assert @ledger.disputed?(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)
  end

  # --- quorums (section 7) ----------------------------------------------------

  def endorse(account, record, ack:, ts: 4_000)
    say(account, ack: ack, endorse: [record.record_hash], ts: ts)
  end

  def quorum(target, endorsements, ack:, by: @tim)
    publish(@ledger, Payload.notice(id: by.id, pubkey: by.pubkey, kind: "quorum", body: "",
                                    target: [target.record_hash], endorse: endorsements.map(&:record_hash),
                                    ack: ack, ts: 5_000), by.working)
  end

  # RULE: an absent adjudicator list names the developer's account, and a
  # quorum counts more than half of the list.
  def test_a_quorum_with_the_adjudicators_endorsement_settles_the_dispute
    ours = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_000)
    theirs = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_001)
    backing = endorse(@tim, ours, ack: [ours.record_hash, theirs.record_hash])
    quorum(ours, [backing], ack: [backing.record_hash])

    refute @ledger.disputed?(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)
    assert_equal "confirmed", @ledger.state(ours.record_hash)
    assert_equal "void", @ledger.state(theirs.record_hash)
  end

  def test_a_quorum_without_a_majority_is_invalid
    ours = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash])
    stranger = Account.new
    declare(@ledger, stranger, ack: [ours.record_hash])
    backing = endorse(stranger, ours, ack: [stranger.id])

    refuses(/more than half/) { quorum(ours, [backing], ack: [backing.record_hash]) }
  end

  # RULE: an adjudicator that endorsed more than one of the conflicting
  # records counts for none of them.
  def test_an_adjudicator_endorsing_both_sides_counts_for_neither
    ours = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_000)
    theirs = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_001)
    both = say(@tim, ack: [ours.record_hash, theirs.record_hash],
                         endorse: [ours.record_hash, theirs.record_hash])

    # With the only adjudicator excluded, none are left, and none is not more
    # than half of none.
    refuses(/more than half of 0/) { quorum(ours, [both], ack: [both.record_hash]) }
  end

  # RULE: once the master key has moved a key, a quorum may name only what the
  # master key reaches -- never the thief's side.
  def test_a_quorum_cannot_name_the_thief_once_the_master_key_has_moved_the_key
    thief = new_key
    stolen = key_change(@alice, to: thief, ack: [@alice_decl.record_hash], ts: 3_000)
    mine = key_change(@alice, to: new_key, ack: [stolen.record_hash], key: @alice.master, ts: 3_001)
    contest = say(@alice, ack: [mine.record_hash], key: thief)
    backing = endorse(@tim, contest, ack: [contest.record_hash])

    refuses(/master key/) { quorum(contest, [backing], ack: [backing.record_hash]) }

    rightful = endorse(@tim, mine, ack: [backing.record_hash], ts: 4_001)
    assert quorum(mine, [rightful], ack: [rightful.record_hash])
    assert_equal "void", @ledger.state(contest.record_hash)
  end

  def test_after_a_quorum_the_void_key_cannot_sign
    ours_key = new_key
    ours = key_change(@alice, to: ours_key, ack: [@alice_decl.record_hash], ts: 3_000)
    thief = new_key
    theirs = key_change(@alice, to: thief, ack: [@alice_decl.record_hash], ts: 3_001)
    backing = endorse(@tim, ours, ack: [ours.record_hash, theirs.record_hash])
    settled = quorum(ours, [backing], ack: [backing.record_hash])

    refuses(/may not sign with/) { say(@alice, ack: [settled.record_hash], key: thief) }
    assert say(@alice, ack: [settled.record_hash], key: ours_key)
  end

  # RULE: a quorum confirms the record it names and the disputed records in
  # its history, and voids only the other disputed records. A -> B -> C -> D
  # in one line, then A -> F and D -> G concurrent with each other.
  def test_a_quorum_confirms_the_line_it_names_and_voids_only_the_rival
    b, c, d, g = Array.new(4) { new_key }
    ab = key_change(@alice, to: b, ack: [@alice_decl.record_hash], ts: 3_000)
    bc = key_change(@alice, to: c, ack: [ab.record_hash], key: b, ts: 3_001)
    cd = key_change(@alice, to: d, ack: [bc.record_hash], key: c, ts: 3_002)
    af = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_003)
    dg = key_change(@alice, to: g, ack: [cd.record_hash], key: d, ts: 3_004)
    backing = endorse(@tim, dg, ack: [dg.record_hash, af.record_hash])
    settled = quorum(dg, [backing], ack: [backing.record_hash])

    [ab, bc, cd, dg].each { |x| assert_equal "confirmed", @ledger.state(x.record_hash) }
    assert_equal "void", @ledger.state(af.record_hash)
    refute @ledger.disputed?(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)

    refuses(/may not sign with/) { say(@alice, ack: [settled.record_hash], key: c) }
    assert say(@alice, ack: [settled.record_hash], key: g)
  end

  def test_had_the_quorum_named_the_rival_it_would_void_the_line
    b = new_key
    ab = key_change(@alice, to: b, ack: [@alice_decl.record_hash], ts: 3_000)
    bc = key_change(@alice, to: new_key, ack: [ab.record_hash], key: b, ts: 3_001)
    af = key_change(@alice, to: new_key, ack: [@alice_decl.record_hash], ts: 3_002)
    backing = endorse(@tim, af, ack: [bc.record_hash, af.record_hash])
    quorum(af, [backing], ack: [backing.record_hash])

    assert_equal "confirmed", @ledger.state(af.record_hash)
    [ab, bc].each { |x| assert_equal "void", @ledger.state(x.record_hash) }
  end

  # RULE: a change nobody disputed is not voided. One in the history of the
  # change a quorum names is confirmed with it, and its key is obsolete.
  def test_an_undisputed_change_in_the_named_history_is_confirmed_and_obsolete
    thief = new_key
    stolen = key_change(@alice, to: thief, ack: [@alice_decl.record_hash], ts: 3_000)
    mine_key = new_key
    mine = key_change(@alice, to: mine_key, ack: [stolen.record_hash], key: @alice.master, ts: 3_001)
    contest = say(@alice, ack: [mine.record_hash], key: thief)
    backing = endorse(@tim, mine, ack: [contest.record_hash])
    settled = quorum(mine, [backing], ack: [backing.record_hash])

    assert_equal "confirmed", @ledger.state(stolen.record_hash)
    assert_equal "void", @ledger.state(contest.record_hash)
    refuses(/may not sign with/) { say(@alice, ack: [settled.record_hash], key: thief) }
    assert say(@alice, ack: [settled.record_hash], key: mine_key)
  end

  # --- compromised and adjudicators (sections 3 and 7) -------------------------

  def test_a_compromised_notice_comes_from_the_account_or_its_adjudicators
    bob = Account.new
    declare(@ledger, bob, ack: [@alice_decl.record_hash])
    notice = ->(by) { Payload.notice(id: by.id, pubkey: by.pubkey, kind: "compromised", body: "",
                                     target: [@alice_decl.record_hash], ack: [bob.id], ts: 3) }

    refuses(/own key or by one of its adjudicators/) { publish(@ledger, notice.call(bob), bob.working) }
    assert publish(@ledger, notice.call(@tim), @tim.working)
    assert @ledger.disputed?(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)
  end

  def test_a_new_adjudicator_list_takes_effect_only_once_endorsed
    bob = Account.new
    declare(@ledger, bob, ack: [@alice_decl.record_hash])
    later = publish(@ledger, Payload.identity(id: @alice.id, pubkey: @alice.pubkey, handle: "Alice",
                                              adjudicators: [bob.id], ack: [bob.id], ts: 3), @alice.working)

    assert_equal [@genesis], @ledger.adjudicators(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)

    endorse(@tim, later, ack: [later.record_hash])
    assert_equal [bob.id], @ledger.adjudicators(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)
  end

  # --- currency (section 11) ------------------------------------------------------

  def arcade_with_tokens(to:, value: "100")
    arcade = Account.new
    declare(@ledger, arcade, ack: [@alice_decl.record_hash], handle: "Arcade",
                             transfer: { "out" => [{ "to" => to.id, "value" => value }] })
    arcade
  end

  def spend(account, currency:, inputs:, out:, ack:, ts: 3_000, **extra)
    say(account, ack: ack, ts: ts, transfer: { "currency" => currency, "in" => inputs, "out" => out }, **extra)
  end

  def test_only_a_currency_can_be_moved
    refuses(/not a currency/) do
      say(@alice, ack: [@alice_decl.record_hash],
                      transfer: { "out" => [{ "to" => @alice.id, "value" => "1" }] })
    end
  end

  def test_a_transfer_spends_exactly_what_it_makes
    arcade = arcade_with_tokens(to: @alice)
    refuses(/spends 100 and makes 99/) do
      spend(@alice, currency: arcade.id, inputs: [arcade.id], out: [{ "to" => @alice.id, "value" => "99" }],
                    ack: [arcade.id])
    end
    assert spend(@alice, currency: arcade.id, inputs: [arcade.id],
                         out: [{ "to" => @alice.id, "value" => "99.5" }, { "to" => arcade.id, "value" => "0.5" }].sort_by { |o| o["to"] },
                         ack: [arcade.id])
  end

  def test_an_output_is_spent_once_along_any_history
    arcade = arcade_with_tokens(to: @alice)
    first = spend(@alice, currency: arcade.id, inputs: [arcade.id], out: [{ "to" => @alice.id, "value" => "100" }],
                          ack: [arcade.id])

    refuses(/already spent/) do
      spend(@alice, currency: arcade.id, inputs: [arcade.id], out: [{ "to" => @alice.id, "value" => "100" }],
                    ack: [first.record_hash])
    end
  end

  def test_an_output_belongs_to_whoever_it_was_paid_to
    arcade = arcade_with_tokens(to: @alice)
    bob = Account.new
    declare(@ledger, bob, ack: [arcade.id])

    refuses(/made no output for this account/) do
      spend(bob, currency: arcade.id, inputs: [arcade.id], out: [{ "to" => bob.id, "value" => "100" }], ack: [bob.id])
    end
  end

  # RULE: a double spend is two valid, conflicting records, and the issuer
  # chooses which stands.
  def test_the_issuer_chooses_between_a_double_spend
    arcade = arcade_with_tokens(to: @alice)
    paid = spend(@alice, currency: arcade.id, inputs: [arcade.id], out: [{ "to" => @alice.id, "value" => "100" }],
                         ack: [arcade.id], ts: 3_000)
    again = spend(@alice, currency: arcade.id, inputs: [arcade.id], out: [{ "to" => @alice.id, "value" => "100" }],
                          ack: [arcade.id], ts: 3_001)
    assert @ledger.disputed?(@alice.id, ReputableChat::Chain::Ledger::EVERYTHING)

    refuses(/both spends/) { endorse_by(arcade, [paid, again]) }
    endorse_by(arcade, [paid])
    assert_equal "void", @ledger.state(again.record_hash)
    refuses(/endorsement of the other/) { endorse_by(arcade, [again], ts: 5_000) }
  end

  def endorse_by(account, records, ts: 4_000)
    ack = (records.map(&:record_hash) + [@ledger.records_of(account.id).last.record_hash]).uniq
    say(account, ack: ack, endorse: records.map(&:record_hash), ts: ts)
  end

  # --- heartbeats (section 10) --------------------------------------------------------

  def server_account
    server = Account.new
    declare(@ledger, server, ack: [@alice_decl.record_hash], handle: "server")
    server
  end

  def beat(server, ack:, ts:)
    publish(@ledger, Payload.heartbeat(id: server.id, pubkey: server.pubkey, ack: ack, ts: ts), server.working)
  end

  def test_a_heartbeat_directly_acknowledges_its_authors_previous_one
    server = server_account
    first = beat(server, ack: [server.id], ts: 10_000)
    later = say(@alice, ack: [first.record_hash])

    refuses(/directly ack/) { beat(server, ack: [later.record_hash], ts: 11_000) }
    assert beat(server, ack: [first.record_hash, later.record_hash], ts: 11_000)
  end

  def test_heartbeats_are_at_least_480_seconds_apart
    server = server_account
    first = beat(server, ack: [server.id], ts: 10_000)

    refuses(/at least 480 seconds/) { beat(server, ack: [first.record_hash], ts: 10_479) }
    assert beat(server, ack: [first.record_hash], ts: 10_480)
  end

  def test_a_heartbeat_carries_nothing_but_acks
    server = server_account
    payload = Payload.heartbeat(id: server.id, pubkey: server.pubkey, ack: [server.id], ts: 1).merge("title" => "x")

    refuses(/does not carry title/) { publish(@ledger, payload, server.working) }
  end

  # RULE: no record may hold both a record and the heartbeat that orphaned it.
  # Reached at 4 heartbeats rather than 256 so the test stays small.
  def test_a_record_may_not_hold_both_sides_of_a_split
    @ledger = ReputableChat::Chain::Ledger.new(genesis: @ledger.genesis, orphan_after: 4)
    @alice_decl = declare(@ledger, @alice, ack: [@genesis], handle: "Alice")
    server = server_account

    previous = beat(server, ack: [server.id], ts: 10_000)
    left_behind = say(@alice, ack: [previous.record_hash])
    4.times { |i| previous = beat(server, ack: [previous.record_hash], ts: 10_480 * (i + 2)) }

    refuses(/orphaned it/) { say(@tim, ack: [left_behind.record_hash, previous.record_hash]) }
    assert say(@tim, ack: [previous.record_hash])
  end
end
