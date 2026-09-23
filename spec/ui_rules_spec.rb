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
    relations = within(app_js, from: "function fillRelations(", lines: 40)

    assert_includes relations, "avatarFor(pubkey)",
                    "friend and blocked lists must show the avatar, like everywhere else"
  end

  # RULE: the genesis account has a face on the account creation screen, where
  # no config has been fetched and none can be -- the account doing the looking
  # does not exist yet. Its icon comes from the declaration already in hand.
  def test_the_genesis_icon_survives_having_no_fetched_config
    icon_for = within(app_js, from: "function iconFor(pubkey)", lines: 12)

    assert_includes icon_for, "genesisProfile(state.genesis)",
                    "the genesis icon must come from its declaration"
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

  # RULE: friend and blocked lists show the whole key. This is the list where
  # somebody checks that who they vouched for is who they meant, and a prefix
  # is exactly what an impersonator would match.
  def test_relations_lists_show_the_whole_key
    relations = within(app_js, from: "function fillRelations(", lines: 45)

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
    assert_includes app_js, "undoReport(message.author, { confirm: false })",
                    "the undo beside a just-blocked message must stay instant"
  end
end
