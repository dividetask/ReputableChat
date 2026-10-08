# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/server_config"
require "tmpdir"

class ServerConfigSpec < Minitest::Test
  Settings = ReputableChat::ServerConfig

  def write(contents)
    path = File.join(@dir, "server.yml")
    File.write(path, contents)
    path
  end

  def setup = @dir = Dir.mktmpdir

  # RULE: the shipped file is what a local run uses, with no environment set.
  # It lists no origin, so a server needs no configuration to run anywhere.
  def test_reads_the_checked_in_file
    settings = Settings.load(env: {})

    assert_equal [], settings["origin"]
    assert_equal "sqlite://data/reputablechat.db", settings["database_url"]
    assert_equal "data/images", settings["image_root"]
  end

  # RULE: the environment wins, so a deployment can inject values without
  # editing a file baked into an image.
  def test_environment_overrides_the_file
    path = write("origin: \"http://from-file.test\"\n")

    settings = Settings.load(path: path, env: { "ORIGIN" => "https://from-env.test" })

    assert_equal ["https://from-env.test"], settings["origin"]
  end

  def test_file_is_used_when_the_environment_is_silent
    path = write("origin: \"http://from-file.test\"\nimage_root: \"/var/img\"\n")

    settings = Settings.load(path: path, env: {})

    assert_equal ["http://from-file.test"], settings["origin"]
    assert_equal "/var/img", settings["image_root"]
  end

  # An empty variable is how a shell exports "unset"; it must not blank the
  # origin and break every login.
  def test_an_empty_environment_variable_falls_through
    path = write("origin: \"http://from-file.test\"\n")

    settings = Settings.load(path: path, env: { "ORIGIN" => "  " })

    assert_equal ["http://from-file.test"], settings["origin"]
  end

  # RULE: an operator may list several origins, in the file or in ORIGIN, and
  # each is spelled the way a browser spells window.location.origin.
  def test_several_origins_are_normalized_like_a_browser
    path = write("origin:\n  - \"HTTPS://Chat.Example.test/\"\n  - \"http://10.0.0.5:80\"\n")

    assert_equal ["https://chat.example.test", "http://10.0.0.5"], Settings.load(path: path, env: {})["origin"]
    assert_equal ["https://a.test", "http://b.test:8080"],
                 Settings.load(path: path, env: { "ORIGIN" => "https://a.test:443, http://b.test:8080" })["origin"]
  end

  # RULE: a malformed origin stops the server at boot, rather than surfacing
  # later as every login failing with a bad signature.
  def test_a_malformed_origin_is_refused_at_boot
    assert_raises(ArgumentError) { Settings.load(path: write("origin: \"chat.example.test\"\n"), env: {}) }
  end

  def test_missing_keys_fall_back_to_defaults
    path = write("origin: \"http://only-this.test\"\n")

    settings = Settings.load(path: path, env: {})

    assert_equal "data/images", settings["image_root"]
  end

  def test_a_missing_or_empty_file_still_yields_defaults
    expected = ReputableChat::ServerConfig::DEFAULTS
               .merge("origin" => [], "limits" => ReputableChat::ServerConfig::LIMITS, "peer_tokens" => [])

    assert_equal expected, Settings.load(path: File.join(@dir, "absent.yml"), env: {})
    assert_equal expected, Settings.load(path: write(""), env: {})
  end

  # RULE: a limit that is absent, unparseable or not positive falls back to the
  # default rather than to zero. A zero would refuse every save, and a typo in a
  # config file must not be able to do that silently.
  def test_a_broken_limit_falls_back_rather_than_to_zero
    default = ReputableChat::ServerConfig::LIMITS.fetch("vault_bytes")

    assert_equal default, Settings.load(path: write("limits:\n  vault_bytes: nonsense\n"), env: {})["limits"]["vault_bytes"]
    assert_equal default, Settings.load(path: write("limits:\n  vault_bytes: 0\n"), env: {})["limits"]["vault_bytes"]
    assert_equal default, Settings.load(path: write("limits:\n  vault_bytes: -5\n"), env: {})["limits"]["vault_bytes"]
  end

  def test_a_limit_is_read_from_the_file_and_the_environment
    path = write("limits:\n  vault_bytes: 2048\n")

    assert_equal 2048, Settings.load(path: path, env: {})["limits"]["vault_bytes"]
    assert_equal 4096, Settings.load(path: path, env: { "VAULT_BYTES" => "4096" })["limits"]["vault_bytes"]
  end

  # RULE: secrets never come from a file that is in the repository.
  def test_secrets_are_not_read_from_the_file
    path = write("session_secret: \"leaked\"\n")

    refute_includes Settings.load(path: path, env: {}).keys, "session_secret"
  end
end
