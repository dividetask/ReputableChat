# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/store/database"
require "tmpdir"

class DatabaseSpec < Minitest::Test
  # RULE: a fresh clone has no data/ directory, because git does not track
  # empty ones. Booting must create it rather than failing to open the file.
  def test_creates_a_missing_parent_directory
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        refute Dir.exist?("data"), "precondition: the directory should be absent"

        ReputableChat::Store::Database.new("sqlite://data/reputablechat.db")

        assert File.exist?("data/reputablechat.db"), "the database file should have been created"
      end
    end
  end

  def test_creates_nested_parent_directories
    Dir.mktmpdir do |root|
      path = File.join(root, "deeply", "nested", "chat.db")
      ReputableChat::Store::Database.new("sqlite://#{path}")

      assert File.exist?(path)
    end
  end

  # RULE: in-memory URLs have no directory to make, and must not be mangled.
  def test_in_memory_databases_still_work
    %w[sqlite:/ sqlite::memory:].each do |url|
      db = ReputableChat::Store::Database.new(url)

      assert db.issue_nonce, "#{url} should be usable"
    end
  end

  # RULE: a database from before records followed the rules is refused, not
  # migrated, and the refusal says which file to delete and what goes with it.
  def test_a_database_from_before_the_rules_is_refused_with_directions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "old.db")
      Sequel.connect("sqlite://#{path}") { |db| db.create_table(:messages) { primary_key :id } }

      error = assert_raises(ReputableChat::Store::Database::LegacySchema) do
        ReputableChat::Store::Database.new("sqlite://#{path}")
      end
      assert_includes error.message, path
      assert_match(/delete that file/, error.message)
      assert_match(/Vaults go with it/, error.message)
    end
  end
end
