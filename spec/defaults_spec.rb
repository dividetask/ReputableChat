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

  # RULE: seeded at creation and nowhere else. Re-adding it whenever it is
  # missing would mean removing it never took, which is the same thing as not
  # being able to remove it. Asserted against the source, because the failure
  # is a second call site rather than a wrong return value.
  def test_the_seed_happens_only_at_identity_creation
    # Read as UTF-8 explicitly: app.js carries emoji, and the default
    # external encoding here is not always.
    app = File.read(File.expand_path("../public/js/app.js", __dir__), encoding: "UTF-8")
    call_sites = app.scan(/initialRatings\(/).size

    assert_equal 1, call_sites,
                 "initialRatings must be called once, in the registration path -- " \
                 "a second call site would re-add a friendship the user removed"
    assert_match(/async function registerWith[\s\S]{0,400}initialRatings\(/, app,
                 "the one call site must be the registration path")
  end
end
