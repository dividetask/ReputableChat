# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "json"
require "socket"
require "tmpdir"
require "securerandom"

# The only tests that look at what a person actually sees.
#
# Everything else about the interface is asserted against the source, which can
# confirm a function is called and cannot notice that it was called with an
# argument that made the picture disappear. That was a real bug, reported by a
# person looking at a screen, while the source assertions passed.
#
# Skipped rather than failed when the browser is not installed: `npm install`
# is not something a clone should have to have done to run `rake spec`.
class BrowserSpec < Minitest::Test
  SCRIPT = File.expand_path("browser/account.mjs", __dir__)
  ROOT   = File.expand_path("..", __dir__)

  def setup
    skip "run `npm install` for the browser tests" unless File.exist?(File.join(ROOT, "node_modules", "playwright-core"))
    skip "no chromium in PLAYWRIGHT_BROWSERS_PATH" if chromium_builds.empty?

    @dir = Dir.mktmpdir
    @port = free_port
    start_server
  end

  def teardown
    stop_server
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def seen
    @seen ||= begin
      stdout, stderr, status = Open3.capture3("node", SCRIPT, "http://127.0.0.1:#{@port}", chdir: ROOT)
      flunk "browser run failed: #{stderr}" unless status.success?

      JSON.parse(stdout.lines.last.to_s)
    end
  end

  def test_the_browser_run_completed
    assert_nil seen["error"], "the browser hit an error: #{seen['error']}"
    assert seen["reached_the_chat"], "never got into the chat"
  end

  # RULE: the new account screen offers one button, and it creates the account.
  def test_the_new_account_screen_shows_one_button
    buttons = seen.fetch("one_button_on_the_new_account_screen")

    assert buttons.fetch("generate_hidden"), "the seed button must not sit beside the create button"
    assert_equal "Create Account", buttons.fetch("submit_label").strip
  end

  # RULE: the genesis account is on the list before the account exists, named
  # and with its face, from the declaration the client already holds.
  def test_the_genesis_account_is_listed_with_its_name_and_face
    assert_equal 1, seen.fetch("friend_rows_before_creating")
    assert_equal "Tim", seen.fetch("genesis_named")
    assert seen.fetch("genesis_has_an_image"), "the genesis avatar must be its image, not a placeholder"
    assert_equal 43, seen.fetch("whole_key_shown").length, "the whole key must be shown"
  end

  # RULE: a pasted key still gets an avatar, so the list looks like one list.
  def test_an_added_key_gets_the_generated_placeholder
    assert_equal 2, seen.fetch("friend_rows_after_adding")
    assert seen.fetch("added_row_has_a_placeholder")
  end

  # RULE: the friendship chosen before the account existed is there afterwards.
  def test_the_chosen_friends_survive_account_creation
    assert_operator seen.fetch("friends_after_creating"), :>=, 1
    assert seen.fetch("friend_list_shows_an_image"), "the friend list must show the avatar"
    assert_equal 43, seen.fetch("friend_list_shows_a_whole_key")
  end

  # RULE: the friend list reads first-added at the top. The ratings come back
  # from the server sorted by public key, because canonical serialization
  # sorts, so this order exists only because the vault records it.
  def test_the_friend_list_is_ordered_by_when_they_were_added
    assert_equal "Tim", seen.fetch("friend_order").first.strip,
                 "the genesis account was added first and belongs at the top"
  end

  # RULE: a rating made during the session counts during that session.
  #
  # Friending somebody does not publish -- the attestation cadence decides that
  # -- so between publishes the author's own vault is the only place the rating
  # exists. The graph has to read it from there or a friend stays invisible
  # until the next republish.
  def test_a_friendship_made_during_the_session_counts_immediately
    assert_equal "Added. They are now trusted.", seen.fetch("added_mid_session"),
                 "a rating made since the last publish must reach this session's scores"
  end

  # RULE: someone this account friended comes out trusted, in the browser, end
  # to end.
  #
  # This is the only test that runs the whole reputation pipeline and looks at
  # the result: the vault's private ratings, the curve, the author's own entry
  # in the graph, the ladder, the bucket. Every other interface test reads
  # app.js as text, and a friend who came out `blocked` would render in the
  # friend list exactly as well as one who came out trusted.
  def test_a_friend_comes_out_trusted
    assert_equal "Tim", seen.fetch("friend_profile_name"),
                 "clicking a friend's name must open that friend's profile"
    assert_equal "Currently trusted this session.", seen.fetch("friend_bucket"),
                 "a friended account must land in the trusted bucket, not merely appear in the list"
  end

  private

  def chromium_builds
    root = ENV.fetch("PLAYWRIGHT_BROWSERS_PATH", "/opt/pw-browsers")
    Dir.exist?(root) ? Dir.children(root).grep(/\Achromium-/) : []
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Its own database and image root, so a browser run never touches real data.
  def start_server
    @server = spawn(
      { "RACK_ENV" => "development",
        "SESSION_SECRET" => SecureRandom.hex(64),
        "ORIGIN" => "http://127.0.0.1:#{@port}",
        "DATABASE_URL" => "sqlite://#{@dir}/browser.db",
        "IMAGE_ROOT" => "#{@dir}/images" },
      "bundle", "exec", "puma", "-p", @port.to_s, "-q",
      chdir: ROOT, out: File::NULL, err: File::NULL
    )
    wait_for_server
  end

  def wait_for_server
    60.times do
      TCPSocket.new("127.0.0.1", @port).close
      return true
    rescue Errno::ECONNREFUSED
      sleep 0.25
    end
    flunk "the server never came up on #{@port}"
  end

  def stop_server
    return unless @server

    Process.kill("TERM", @server)
    Process.wait(@server)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
