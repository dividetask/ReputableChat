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
end
