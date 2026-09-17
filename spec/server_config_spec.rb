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
  def test_reads_the_checked_in_file
    settings = Settings.load(env: {})

    assert_equal "http://localhost:9292", settings["origin"]
    assert_equal "sqlite://data/reputablechat.db", settings["database_url"]
    assert_equal "data/images", settings["image_root"]
  end

  # RULE: the environment wins, so a deployment can inject values without
  # editing a file baked into an image.
  def test_environment_overrides_the_file
    path = write("origin: \"http://from-file.test\"\n")

    settings = Settings.load(path: path, env: { "ORIGIN" => "https://from-env.test" })

    assert_equal "https://from-env.test", settings["origin"]
  end

  def test_file_is_used_when_the_environment_is_silent
    path = write("origin: \"http://from-file.test\"\nimage_root: \"/var/img\"\n")

    settings = Settings.load(path: path, env: {})

    assert_equal "http://from-file.test", settings["origin"]
    assert_equal "/var/img", settings["image_root"]
  end

  # An empty variable is how a shell exports "unset"; it must not blank the
  # origin and break every login.
  def test_an_empty_environment_variable_falls_through
    path = write("origin: \"http://from-file.test\"\n")

    settings = Settings.load(path: path, env: { "ORIGIN" => "  " })

    assert_equal "http://from-file.test", settings["origin"]
  end

  def test_missing_keys_fall_back_to_defaults
    path = write("origin: \"http://only-this.test\"\n")

    settings = Settings.load(path: path, env: {})

    assert_equal "data/images", settings["image_root"]
  end

  def test_a_missing_or_empty_file_still_yields_defaults
    assert_equal ReputableChat::ServerConfig::DEFAULTS,
                 Settings.load(path: File.join(@dir, "absent.yml"), env: {})
    assert_equal ReputableChat::ServerConfig::DEFAULTS,
                 Settings.load(path: write(""), env: {})
  end

  # RULE: secrets never come from a file that is in the repository.
  def test_secrets_are_not_read_from_the_file
    path = write("session_secret: \"leaked\"\n")

    refute_includes Settings.load(path: path, env: {}).keys, "session_secret"
  end
end
