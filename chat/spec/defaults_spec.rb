# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "json"

# What a new identity declares on the day it is made.
class DefaultsSpec < Minitest::Test
  include SpecHelper

  SCRIPT = File.expand_path("defaults.mjs", __dir__)

  def defaults
    @defaults ||= begin
      stdout, stderr, status = Open3.capture3("node", SCRIPT)
      flunk "node failed: #{stderr}" unless status.success?

      JSON.parse(stdout)
    end
  end

  def setup
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  # RULE: a new identity friends the genesis account. Without it a newcomer
  # sees nothing -- an unrated account sits at exactly zero and is invisible to
  # everyone, so a network where nobody has vouched for anybody shows nobody.
  def test_a_new_identity_friends_the_genesis_account
    rating = defaults.fetch("newcomer").fetch(defaults.fetch("genesis_key"))

    assert rating.fetch("friend")
    refute rating.fetch("reported")
  end

  # RULE: it is an ordinary rating, not a special case. It appears in the
  # friend list beside everyone else and can be removed like anyone else -- a
  # trust that cannot be seen or withdrawn is a policy wearing a default's
  # clothes, and the whole project exists to avoid a reputation nobody chose.
  def test_the_seeded_friendship_is_an_ordinary_rating
    rating = defaults.fetch("newcomer").fetch(defaults.fetch("genesis_key"))

    assert_equal %w[cleared friend net_votes reported], rating.keys.sort
    assert_equal 0, rating.fetch("net_votes")
  end

  # RULE: the genesis account does not vouch for itself. Nobody contributes to
  # their own score anywhere else either.
  def test_the_genesis_account_does_not_friend_itself
    assert_empty defaults.fetch("genesis_itself")
  end

  def test_nothing_is_seeded_without_a_genesis
    assert_empty defaults.fetch("no_genesis")
  end

  # RULE: a server with a host account gives a new identity two default
  # friends, the genesis account and the host account. Both are ordinary
  # friendships, removable like any other.
  def test_a_server_with_a_host_account_seeds_both_default_friends
    seeded = defaults.fetch("newcomer_with_host")

    assert_equal [defaults.fetch("genesis_key"), defaults.fetch("host_key")].sort, seeded.keys.sort
    seeded.each_value { |rating| assert rating.fetch("friend") }
  end

  # RULE: a host account is optional. Without one the genesis account is the
  # only default friend.
  def test_a_server_without_a_host_account_seeds_the_genesis_alone
    assert_equal [defaults.fetch("genesis_key")], defaults.fetch("newcomer").keys
  end

  # RULE: the host account does not vouch for itself either.
  def test_the_host_account_does_not_friend_itself
    assert_equal [defaults.fetch("genesis_key")], defaults.fetch("host_itself").keys
  end

  # RULE: the genesis account's name is shown, not a placeholder. Every other
  # name comes from a fetched config and the genesis has none -- it has an
  # identity declaration. Without reading it, the one account everybody trusts
  # by default is the one account nobody can see the name of.
  def test_the_genesis_handle_is_read_from_its_declaration
    profile = defaults.fetch("genesis_profile")

    assert_equal "Tim", profile.fetch("handle")
    assert_equal "Legally distinct.", profile.fetch("bio")
  end

  # A declaration that cannot be read yields nothing rather than a broken
  # profile, so a bad genesis shows a fingerprint instead of a wrong name.
  def test_an_unreadable_declaration_yields_no_profile
    assert_nil defaults.fetch("genesis_profile_no_handle")
    assert_nil defaults.fetch("genesis_profile_malformed")
    assert_nil defaults.fetch("genesis_profile_missing")
  end

  # RULE: the seeded profile must not beat an identity declaration a default
  # friend has since published. It is a fallback for having nothing, not a pin.
  def test_the_seeded_profile_is_set_before_the_walk_fetches_declarations
    app = File.read(File.expand_path("../public/js/app.js", __dir__), encoding: "UTF-8")
    seeded = app.index("declarationProfile(record)")
    fetched = app.index("state.profiles.set(blob.pubkey")

    refute_nil seeded, "the default friends' profiles are never seeded"
    refute_nil fetched, "fetched declarations never populate profiles"
    assert_operator seeded, :<, fetched,
                    "seed the genesis profile before fetched declarations overwrite it"
  end

  # RULE: seeded once, when account creation begins, and never re-applied.
  # Re-adding it whenever it is missing would mean removing it never took,
  # which is the same thing as not being able to remove it. Asserted against
  # the source, because the failure is a second call site rather than a wrong
  # return value.
  def test_the_seed_happens_only_when_account_creation_begins
    assert_equal 1, app_js.scan(/initialRatings\(/).size,
                 "initialRatings must be called once -- a second call site would " \
                 "re-add a friendship the user removed"
    assert_match(/function resetNewFriends\(\)[\s\S]{0,300}initialRatings\(/, app_js,
                 "the one call site must be the account creation screen's reset")
  end

  # RULE: what gets published is the list the person left on the screen, not a
  # freshly seeded one. Seeding at publish time would quietly put the genesis
  # account back after they took it off.
  def test_registration_publishes_the_list_the_screen_was_left_with
    register = app_js[/async function registerWith[\s\S]{0,1800}?\n\}/]
    refute_nil register, "registerWith not found"

    assert_includes register, "state.newFriends", "registration must publish the chosen list"
    refute_includes register, "initialRatings(",
                    "registration must not re-seed, or removing the genesis would not take"
  end

  # RULE: the screen is re-seeded only on the two ways into account creation.
  # Re-seeding on every render would restore the genesis on the next repaint.
  def test_the_screen_is_reseeded_only_when_entering_account_creation
    assert_equal 2, app_js.scan(/resetNewFriends\(\);/).size,
                 "reset belongs to the two entries into account creation and nowhere else"
    refute_match(/function renderRoute\(\)[\s\S]{0,400}resetNewFriends/, app_js,
                 "rendering the route must not re-seed the list")
  end

  # RULE: a key pasted on the new account screen must look like a key. The
  # field takes raw base64url, so it is the only thing standing between a
  # typo and a friendship with nobody.
  def test_a_pasted_friend_key_is_validated
    add = app_js[/function addNewFriend\(\)[\s\S]{0,900}?\n\}/]
    refute_nil add, "addNewFriend not found"

    assert_includes add, "PUBKEY.test(pubkey)", "a pasted key must be checked"
    assert_includes add, "state.me?.pubkey", "their own key must be refused"
    assert_includes add, "state.newFriends[pubkey]", "duplicates must be refused"
  end

  # app.js carries emoji, and the default external encoding here is not always
  # UTF-8.
  def app_js
    @app_js ||= File.read(File.expand_path("../public/js/app.js", __dir__), encoding: "UTF-8")
  end
end
