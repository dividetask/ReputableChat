# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/bot/categories"
require "reputable_chat/bot/roster"
require "tmpdir"
require "json"

# The categories file is prose for the model and rules for the script at the
# same time. The prose can be argued about; the rules cannot drift, because
# "a scammer never posts a live link" has to be something the code does rather
# than something the file asks for.
class BotCategoriesSpec < Minitest::Test
  Categories = ReputableChat::Bot::Categories
  Roster     = ReputableChat::Bot::Roster

  EXPECTED = %w[gullible bot realperson expert scammer spammer troll].freeze

  def categories = @categories ||= Categories.load

  def test_every_category_the_personas_use_is_defined
    assert_equal EXPECTED.sort, categories.names.sort
  end

  def test_the_shipped_personas_all_name_a_category_that_exists
    Dir.glob(File.expand_path("../personas/*.yml", __dir__)).each do |path|
      named = YAML.safe_load_file(path)["category"]

      assert categories.known?(named), "#{File.basename(path)} is a #{named.inspect}, which is not defined"
    end
  end

  # The briefing is what the model is actually told it is, so an empty one
  # means a whole category of bot behaves like nothing in particular.
  def test_every_category_briefs_the_model_with_something
    categories.names.each do |name|
      briefing = categories.fetch(name).briefing

      assert_operator briefing.length, :>, 80, "#{name} barely says anything"
      assert_match(/\A#{name}:/, briefing)
    end
  end

  # Only the two categories that are meant to be posting links may, and even
  # they only get the safe ones.
  def test_only_the_accounts_that_should_post_links_can
    posting = categories.names.select { |name| categories.fetch(name).posts_links? }

    assert_equal %w[scammer spammer].sort, posting.sort
  end

  def test_a_relative_safe_link_is_served_by_the_server_under_test
    links = categories.safe_links(origin: "https://chat.example/")

    refute_empty links
    assert_includes links, "https://chat.example/caught.html"
    assert(links.all? { |link| link.start_with?("http") }, "a safe link was left relative: #{links}")
  end

  def test_an_unknown_link_policy_is_refused_rather_than_ignored
    error = assert_raises(Categories::Malformed) do
      Categories.new({ "categories" => { "x" => { "definition" => "d", "links" => "sure, why not" } } })
    end

    assert_match(/links:/, error.message)
  end

  def test_asking_for_a_category_that_does_not_exist_says_which_do
    error = assert_raises(Categories::Unknown) { categories.fetch("wizard") }

    assert_match(/gullible/, error.message)
  end

  # A gullible account befriending scammers is the behaviour under test, so it
  # is arranged rather than hoped for -- no small model works out who is worth
  # trusting.
  def test_the_gullible_are_drawn_to_exactly_the_people_who_will_use_them
    assert_equal %w[scammer spammer], categories.fetch("gullible").drawn_to
    assert_empty categories.fetch("realperson").drawn_to
  end

  # --- the roster ---------------------------------------------------------

  def with_roster
    Dir.mktmpdir do |dir|
      write(dir, "a", "KEY-A", "scammer")
      write(dir, "b", "KEY-B", "realperson")
      write(dir, "c", "KEY-C", "spammer")
      File.write(File.join(dir, "vouchers.json"), JSON.generate("vouchers" => []))
      yield dir
    end
  end

  def write(dir, name, pubkey, category)
    File.write(File.join(dir, "#{name}.json"),
               JSON.generate("name" => name, "pubkey" => pubkey,
                             "username" => name.upcase, "category" => category))
  end

  def test_the_roster_is_the_other_bots_on_this_machine
    with_roster do |dir|
      members = Roster.read(dir, except: "KEY-B")

      assert_equal %w[KEY-A KEY-C].sort, members.map(&:pubkey).sort
      assert_equal "scammer", members.find { |m| m.pubkey == "KEY-A" }.category
    end
  end

  def test_the_voucher_pool_is_not_mistaken_for_a_bot
    with_roster do |dir|
      refute_includes Roster.read(dir).map(&:name), "vouchers"
    end
  end

  def test_a_half_written_state_file_is_skipped_rather_than_fatal
    with_roster do |dir|
      File.write(File.join(dir, "broken.json"), "{ not json")

      assert_equal 3, Roster.read(dir).size
    end
  end

  def test_a_bot_drawn_to_nobody_present_still_picks_somebody
    with_roster do |dir|
      members = Roster.read(dir)
      chosen  = Roster.preferred(members, Categories.current.fetch("realperson"), random: Random.new(1))

      refute_nil chosen
    end
  end

  def test_a_gullible_bot_mostly_picks_the_people_it_should_not
    with_roster do |dir|
      members = Roster.read(dir)
      gullible = Categories.current.fetch("gullible")
      picks = Array.new(200) { |i| Roster.preferred(members, gullible, random: Random.new(i)).category }

      assert_operator picks.count { |c| %w[scammer spammer].include?(c) }, :>, 120,
                      "a gullible bot should mostly end up with the wrong people"
    end
  end
end
