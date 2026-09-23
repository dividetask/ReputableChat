# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "json"

# Who is called what, from one viewer's position.
#
# Handles are not unique and never will be, so something has to decide which
# Joe is "Joe". The rule is seniority, and the order it is measured in is what
# makes it useful: an impersonator always arrives after the person they are
# copying, so they are always the one wearing the suffix.
class NamesSpec < Minitest::Test
  SCRIPT = File.expand_path("names.mjs", __dir__)

  A = "a" * 43
  B = "b" * 43
  C = "c" * 43
  D = "d" * 43

  def setup
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def seen
    @seen ||= begin
      stdout, stderr, status = Open3.capture3("node", SCRIPT)
      flunk "node failed: #{stderr}" unless status.success?

      JSON.parse(stdout.lines.last)
    end
  end

  # RULE: a handle nobody else is using needs no qualification. The suffix is
  # for telling people apart, and there is nobody to tell apart.
  def test_an_uncontested_handle_is_shown_bare
    assert_nil seen.fetch("unique_handle").fetch("suffix")
  end

  # RULE: friends outrank sightings outright. Somebody you chose is more yours
  # than somebody who merely turned up first.
  def test_a_friend_takes_the_name_from_an_older_sighting
    resolved = seen.fetch("friend_beats_older_sighting")

    assert_nil resolved.fetch(B).fetch("suffix"), "the friend keeps the bare name"
    assert_equal "a" * 8, resolved.fetch(A).fetch("suffix"), "the older sighting is qualified"
  end

  # RULE: between two friends, the one added first keeps the name. That order
  # comes from the vault, because canonical serialization sorts the ratings by
  # public key -- leaving it to key order would let an impersonator grind a key
  # that sorts above yours and take your name.
  def test_between_friends_the_earlier_addition_keeps_the_name
    resolved = seen.fetch("friends_use_list_order")

    assert_nil resolved.fetch(A).fetch("suffix")
    assert_equal "b" * 8, resolved.fetch(B).fetch("suffix")
  end

  def test_between_sightings_the_earlier_one_keeps_the_name
    resolved = seen.fetch("sightings_use_seniority")

    assert_nil resolved.fetch(B).fetch("suffix"), "seen first, so it holds the name"
    assert_equal "a" * 8, resolved.fetch(A).fetch("suffix")
  end

  # RULE: somebody neither chosen nor seen before sorts last. A stranger never
  # takes a contested name off an account the viewer has a record of.
  def test_a_stranger_does_not_take_a_contested_name
    resolved = seen.fetch("stranger_loses")

    assert_nil resolved.fetch(A).fetch("suffix")
    assert_equal "d" * 8, resolved.fetch(D).fetch("suffix")
  end

  # RULE: a rename starts seniority over. Otherwise an account seen long ago
  # could rename itself to somebody else's handle and outrank them on seniority
  # it never earned under that name.
  def test_renaming_forfeits_seniority
    entry = seen.fetch("rename_restarts_seniority").first

    assert_equal "Bob", entry.fetch("handle")
    assert_equal 50, entry.fetch("at"), "the clock restarts at the rename"
  end

  def test_being_seen_again_under_the_same_handle_keeps_seniority
    assert_equal 1, seen.fetch("same_handle_keeps_seniority").first.fetch("at")
  end

  # RULE: friends and blocked accounts leave the set. One is ranked above it,
  # the other is never shown, so a record of either is one nothing reads.
  def test_a_sighting_can_be_forgotten
    assert_equal [B], seen.fetch("forgetting").map { |entry| entry.fetch("pubkey") }
  end

  # RULE: over budget, the newest sightings go. Seniority is the entire content
  # of this set, so dropping the oldest would throw away what it records.
  def test_pruning_keeps_the_oldest_sightings
    assert_equal [1, 2], seen.fetch("prune_keeps_the_oldest")
  end

  # RULE: merging two devices keeps the earlier sighting, because when it
  # happened is the whole point of the record.
  def test_merging_keeps_the_earlier_sighting
    merged = seen.fetch("merge_keeps_the_earlier")
    first = merged.find { |entry| entry.fetch("pubkey") == A }

    assert_equal 2, first.fetch("at")
    assert_equal 2, merged.length, "the other device's sightings survive"
  end

  # The suffix is the same eight characters the fingerprint has always been, so
  # they are one string to learn rather than two.
  def test_the_suffix_is_the_fingerprint
    assert_equal 8, seen.fetch("suffix_length")
  end
end
