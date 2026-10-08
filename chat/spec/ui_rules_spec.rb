# frozen_string_literal: true

require_relative "spec_helper"

# Rules about the interface that have no other guard.
#
# There is no DOM harness in this project, so these read the source rather than
# the rendered page. That is weaker than driving a browser and it is honest
# about what it catches: a rule being deleted, not a rule being broken subtly.
# Each one is here because it was reported as a bug by somebody using the app.
class UiRulesSpec < Minitest::Test
  def app_js
    @app_js ||= File.read(File.expand_path("../public/js/app.js", __dir__), encoding: "UTF-8")
  end

  def within(source, from:, lines: 20)
    start = source.index(from) or flunk("could not find #{from.inspect}")
    source[start, source[start, 4_000].lines.first(lines).join.length]
  end

  # RULE: the new account screen has one button and it creates the account.
  # Two buttons there read as two destinations when only one goes anywhere --
  # the second only regenerated the seed already on screen.
  def test_the_new_account_screen_offers_one_button
    route = within(app_js, from: "function renderRoute()")

    assert_includes route, '$("generate").classList.toggle("hidden", newAccount)',
                    "the seed-generating button must be hidden on the new account screen"
    assert_match(/\$\("unlock"\)\.textContent = newAccount \?/, route,
                 "the remaining button must say what it does on each screen")
  end

  # RULE: a person is shown with their avatar wherever they are named. The
  # friend list was the one place that named somebody without one.
  def test_relations_lists_show_avatars
    relations = within(app_js, from: "function fillRelations(", lines: 60)

    assert_includes relations, "avatarFor(pubkey)",
                    "friend and blocked lists must show the avatar, like everywhere else"
  end

  # RULE: the default friends -- the genesis account and the host account --
  # have faces on the account creation screen, where nothing has been fetched
  # and nothing can be. Their icons come from the declarations already in hand.
  def test_default_friend_icons_survive_having_nothing_fetched
    icon_for = within(app_js, from: "function iconFor(pubkey)", lines: 12)

    assert_includes icon_for, "declarationProfile(committedFor(pubkey))",
                    "a default friend's icon must come from its committed declaration"
    assert_match(/function committedFor[\s\S]{0,200}state\.genesis, state\.host/, app_js,
                 "both default friends must be looked up")
    refute_includes app_js, 'avatarFor(pubkey, "", null)',
                    "passing a null icon defeats the lookup the default performs"
  end

  # RULE: the overlay never takes pointer events. It opens on hover and closes
  # when the pointer leaves the small image; an overlay that swallowed the
  # pointer would cover the thing keeping it open and flicker between states.
  def test_the_enlarged_avatar_does_not_swallow_the_pointer
    css = File.read(File.expand_path("../public/css/app.css", __dir__), encoding: "UTF-8")
    lightbox = css[/#lightbox \{[^}]*\}/]

    refute_nil lightbox, "#lightbox has no rule"
    assert_includes lightbox, "pointer-events: none"
  end

  # RULE: an avatar is a way to reach somebody's profile; the avatar already on
  # that profile is the end of the journey, so it is the one that enlarges.
  def test_an_avatar_opens_a_profile_and_the_profile_one_enlarges
    opens = within(app_js, from: "function opensProfile(", lines: 18)
    enlarges = within(app_js, from: "function enlarges(", lines: 14)

    assert_includes opens, "showProfile(pubkey)"
    assert_includes enlarges, "showLarge(source)"
    assert_match(/const onProfile = extra\.includes\("avatar-large"\)/, app_js,
                 "which behaviour an avatar gets must follow from where it is")
  end

  # RULE: hovering waits before it acts. Without a dwell, crossing a list of
  # messages would open every profile on the way past, which is worse than no
  # hover at all. A tap never waits -- it is not a hover.
  def test_hovering_waits_but_tapping_does_not
    opens = within(app_js, from: "function opensProfile(", lines: 18)

    assert_includes opens, "HOVER_INTENT_MS", "hover must dwell before opening"
    assert_includes opens, "clearTimeout(waiting)", "leaving must cancel a pending open"
  end

  # RULE: adding somebody from the profile page shows them straight away. The
  # list is already on screen, so not repainting it reads as the add failing.
  def test_adding_a_friend_repaints_the_list
    add = app_js[/async function addByKey\(\)[\s\S]{0,900}?\n\}/]
    refute_nil add, "addByKey not found"

    assert_includes add, "renderRelations()", "the friend list must repaint"
  end

  # RULE: friend and blocked lists show the whole key. This is the list where
  # somebody checks that who they vouched for is who they meant, and a prefix
  # is exactly what an impersonator would match.
  def test_relations_lists_show_the_whole_key
    relations = within(app_js, from: "function fillRelations(", lines: 60)

    assert_includes relations, "key.textContent = pubkey", "the full key must be shown"
    refute_includes relations, "fingerprint(pubkey)", "a prefix is not enough here"
  end

  # RULE: withdrawing a vouch asks first. Unfriending silently drops everything
  # that person vouches for, which is not a thing to do on a stray click.
  def test_unfriending_asks_first
    unfriend = within(app_js, from: "async function unfriend(pubkey)", lines: 12)

    assert_includes unfriend, "confirmAction", "unfriending must confirm"
    assert_match(/if \(!sure\) return/, unfriend, "declining must abandon the change")
  end

  # RULE: unblocking asks first too -- it re-admits somebody who was blocked.
  # The exception is the undo beside a message just blocked, which exists for a
  # misclick: a dialog there would guard the wrong direction.
  def test_unblocking_asks_first_except_when_undoing_a_misclick
    undo = within(app_js, from: "async function undoReport(pubkey", lines: 14)

    assert_includes undo, "confirm = true",
                    "the default must be to ask, so a later call site asks by default"
    assert_includes app_js, "undoReport(message.pubkey, { confirm: false })",
                    "the undo beside a just-blocked message must stay instant"
  end
end
