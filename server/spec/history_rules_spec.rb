# frozen_string_literal: true

require_relative "spec_helper"

# The rules that turn on a record's history (sections 2, 3, 7, 8, 10 and 11).
class HistoryRulesSpec < Minitest::Test
  include ChainHelpers

  def setup
    setup_chain
    @bob = declare("bob").digest
    @carol = declare("carol", ack: [@bob]).digest
  end

  def notice(name, account, kind, ack:, field: "pubkey", **extra)
    sign(name, { "ack" => ack.sort, "id" => account, "type" => "reputablechat:notice:#{version}", "kind" => kind }
                 .merge(extra.transform_keys(&:to_s)), field: field)
  end

  # --- history and accounts -----------------------------------------------------

  def test_a_record_waits_for_what_it_acknowledges_then_joins
    first = post("bob", @bob, ack: [@carol], body: "first")
    second = post("bob", @bob, ack: [first.digest], body: "second")

    assert_equal :pending, @ingest.submit(second).status
    accept(first)
    assert @store.known?(second.digest), "the held record was not accepted once its parent arrived"
  end

  def test_id_names_a_first_declaration_in_the_records_history
    dave = declare("dave").digest
    refuse(post("dave", dave, ack: [@bob]), /id names no first identity declaration/)
  end

  def test_a_record_signed_by_a_key_the_account_never_had_is_refused
    refuse(post("mallory", @bob, ack: [@carol]), /neither the account's last confirmed key/)
  end

  def test_a_record_acks_only_records_of_its_own_version
    load_examples
    release = Examples.records.find { |r| r["type"] == "reputablechat:release:v0.002" }
    refuse(post("bob", @bob, ack: [release.digest]), /acks a record of v0.002/)
  end

  def test_endorse_names_only_records_in_the_history
    later = accept(post("carol", @carol, ack: [@carol], body: "later"))
    refuse(post("bob", @bob, ack: [@bob], endorse: [later.digest]), /endorse names a record outside/)
  end

  # --- keys -------------------------------------------------------------------------

  def test_a_superseded_key_still_signs_and_contests_the_change
    change = accept(notice("bob", @bob, "key-change", ack: [@carol], body: pub("bob-new")))
    accept(post("bob-new", @bob, ack: [change.digest], body: "new key"))
    contest = accept(post("bob", @bob, ack: [change.digest], body: "that was not me"))

    assert @store.fetch(contest.digest).facts["contests"]
    later = post("carol", @carol, ack: [contest.digest])
    view = Agnostic::View.of(later, store: @store, histories: Agnostic::Histories.new(@store), genesis: tim)
    assert view.disputed?(@bob), "a contest disputes the account"
  end

  def test_a_master_key_change_is_signed_with_the_current_master_key
    erin = declare("erin", mpubkey: pub("erin-master")).digest
    refuse(notice("erin", erin, "master-key-change", ack: [erin], body: pub("erin-master-2")),
           /signed with the current master key/)
    accept(notice("erin-master", erin, "master-key-change", ack: [erin], body: pub("erin-master-2"),
                                                            field: "mpubkey"))
  end

  def test_an_account_without_a_master_key_cannot_change_one
    refuse(notice("bob", @bob, "master-key-change", ack: [@carol], body: pub("bob-master")),
           /signed with the current master key/)
  end

  # --- quorums and adjudicators ---------------------------------------------------------

  def test_a_quorum_needs_more_than_half_of_the_adjudicators
    change = accept(notice("carol", @carol, "key-change", ack: [@carol], body: pub("carol-new")))
    refuse(notice("tim", tim, "quorum", ack: [change.digest], target: [change.digest]), /more than half/)

    endorsement = accept(post("tim", tim, ack: [change.digest], body: "Confirmed with Carol.", endorse: [change.digest]))
    quorum = accept(notice("tim", tim, "quorum", ack: [endorsement.digest], target: [change.digest],
                                                 endorse: [endorsement.digest]))

    refuse(post("carol", @carol, ack: [quorum.digest]), /neither the account's last confirmed key/)
    accept(post("carol-new", @carol, ack: [quorum.digest]))
  end

  def test_a_quorum_voids_the_changes_tentative_when_it_was_signed
    mine = accept(notice("carol", @carol, "key-change", ack: [@carol], body: pub("carol-new")))
    theirs = accept(notice("carol", @carol, "key-change", ack: [@carol], body: pub("carol-thief"), ts: @now + 1))
    endorsement = accept(post("tim", tim, ack: [mine.digest, theirs.digest], endorse: [mine.digest]))
    quorum = accept(notice("tim", tim, "quorum", ack: [endorsement.digest], target: [mine.digest],
                                                 endorse: [endorsement.digest]))

    refuse(post("carol-thief", @carol, ack: [quorum.digest]), /neither the account's last confirmed key/)
    refuse(notice("tim", tim, "quorum", ack: [quorum.digest], target: [theirs.digest]), /already void/)
  end

  # A quorum confirms the record it names and the disputed records in its
  # history, and voids only the other disputed records: A -> B -> C -> D in
  # one line, then A -> F and D -> G concurrent with each other.
  def test_a_quorum_confirms_the_line_it_names_and_voids_only_the_rival
    ab = accept(notice("carol", @carol, "key-change", ack: [@carol], body: pub("carol-b")))
    bc = accept(notice("carol-b", @carol, "key-change", ack: [ab.digest], body: pub("carol-c")))
    cd = accept(notice("carol-c", @carol, "key-change", ack: [bc.digest], body: pub("carol-d")))
    af = accept(notice("carol", @carol, "key-change", ack: [@carol], body: pub("carol-f"), ts: @now + 1))
    dg = accept(notice("carol-d", @carol, "key-change", ack: [cd.digest], body: pub("carol-g")))
    endorsement = accept(post("tim", tim, ack: [af.digest, dg.digest], endorse: [dg.digest]))
    quorum = accept(notice("tim", tim, "quorum", ack: [endorsement.digest], target: [dg.digest],
                                                 endorse: [endorsement.digest]))

    accept(post("carol-g", @carol, ack: [quorum.digest]))
    %w[carol-c carol-f].each do |obsolete_or_void|
      refuse(post(obsolete_or_void, @carol, ack: [quorum.digest]), /neither the account's last confirmed key/)
    end
    refuse(notice("tim", tim, "quorum", ack: [quorum.digest], target: [af.digest]), /already void/)
  end

  def test_compromised_is_signed_by_the_account_or_one_of_its_adjudicators
    refuse(notice("bob", @bob, "compromised", ack: [@carol], target: [@carol]), /the account or one of its adjudicators/)
    accept(notice("carol", @carol, "compromised", ack: [@carol], target: [@carol]))
    accept(notice("tim", tim, "compromised", ack: [@carol], target: [@carol], ts: @now + 1))
  end

  def test_a_new_adjudicator_list_takes_effect_once_the_list_in_force_endorses_it
    proposal = accept(sign("carol", { "ack" => [@carol], "id" => @carol, "title" => "Carol",
                                      "type" => "reputablechat:identity:#{version}", "adjudicators" => [@bob] }))
    refuse(notice("bob", @bob, "compromised", ack: [proposal.digest], target: [@carol]), /adjudicators/)

    endorsement = accept(post("tim", tim, ack: [proposal.digest], endorse: [proposal.digest]))
    accept(notice("bob", @bob, "compromised", ack: [endorsement.digest], target: [@carol]))
  end

  # --- currency -------------------------------------------------------------------------

  def issue_to_bob
    accept(sign("arcade", { "ack" => [@carol], "title" => "Arcade", "type" => "reputablechat:identity:#{version}",
                            "transfer" => { "out" => [{ "to" => @bob, "value" => "100" }] } }))
  end

  def spend(output, arcade, ack:, to: @carol, keep: "99", ts: @now)
    out = [{ "to" => @bob, "value" => keep }, { "to" => to, "value" => (100 - keep.to_i).to_s }].sort_by { |o| o["to"] }
    post("bob", @bob, ack: ack, ts: ts, transfer: { "currency" => arcade, "in" => [output], "out" => out })
  end

  def test_only_a_currency_may_issue
    refuse(post("bob", @bob, ack: [@carol], transfer: { "out" => [{ "to" => @bob, "value" => "5" }] }), /not a currency/)
  end

  def test_a_spend_pays_only_accounts_in_its_history
    arcade = issue_to_bob.digest
    dave = declare("dave").digest
    refuse(spend(arcade, arcade, ack: [arcade], to: dave), /not in this record's history/)
  end

  def test_an_output_spent_in_the_history_cannot_be_spent_again
    arcade = issue_to_bob.digest
    paid = accept(spend(arcade, arcade, ack: [arcade]))
    refuse(spend(arcade, arcade, ack: [paid.digest], ts: @now + 1), /already spent/)
  end

  def test_a_spend_of_another_currency_is_refused
    arcade = issue_to_bob.digest
    refuse(spend(arcade, tim, ack: [arcade]), /not a currency|another currency/)
  end

  def test_the_issuer_chooses_one_double_spend_and_nobody_endorses_both
    arcade = issue_to_bob.digest
    one = accept(spend(arcade, arcade, ack: [arcade]))
    two = accept(spend(arcade, arcade, ack: [arcade], keep: "98", ts: @now + 1))

    refuse(post("arcade", arcade, ack: [one.digest, two.digest], endorse: [one.digest, two.digest]), /both spends/)
    choice = accept(post("arcade", arcade, ack: [one.digest, two.digest], endorse: [one.digest]))
    refuse(post("tim", tim, ack: [choice.digest], endorse: [two.digest]), /issuer chose the other/)
  end

  # --- heartbeats -------------------------------------------------------------------------

  def beat(ack:, ts:) = post("bob", @bob, ack: ack, ts: ts, type: "reputablechat:heartbeat:#{version}")

  def test_a_heartbeat_directly_acks_its_authors_previous_one_at_least_480_seconds_later
    first = accept(beat(ack: [@carol], ts: @now))
    between = accept(post("carol", @carol, ack: [first.digest]))

    refuse(beat(ack: [between.digest], ts: @now + 600), /directly acks/)
    refuse(beat(ack: [first.digest], ts: @now + 479), /at least 480 seconds/)
    accept(beat(ack: [first.digest, between.digest], ts: @now + 480))
  end

  # A record that acknowledged only an old heartbeat cannot be joined once the
  # publisher has beaten 256 times past it.
  def test_no_history_holds_a_record_and_the_heartbeat_that_orphaned_it
    beats = [accept(beat(ack: [@carol], ts: @now))]
    stale = accept(post("carol", @carol, ack: [beats.first.digest], body: "left behind"))
    257.times { beats << accept(beat(ack: [beats.last.digest], ts: @now += 480)) }

    joined_in_time = post("tim", tim, ack: [stale.digest, beats[255].digest])
    accept(joined_in_time)
    refuse(post("tim", tim, ack: [stale.digest, beats[256].digest], ts: @now + 1), /orphaned/)
  end
end
