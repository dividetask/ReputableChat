# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/cryptography/record"
require "open3"
require "json"

# `ack` names a record by its hash, so the browser and the server have to agree
# on what that hash is. If they ever disagree, every client builds a chain the
# server cannot follow and no reference resolves -- with nothing failing loudly
# to say why. Same failure mode as canonical_parity_spec, one layer up.
class RecordParitySpec < Minitest::Test
  Record  = ReputableChat::Cryptography::Record

  RECORDS = File.expand_path("fixtures/record_vectors.json", __dir__)
  SCRIPT  = File.expand_path("record_parity.mjs", __dir__)

  def test_ruby_and_javascript_hash_records_identically
    skip "node is not installed" unless node?

    stdout, stderr, status = Open3.capture3("node", SCRIPT)
    flunk "node failed: #{stderr}" unless status.success?

    lines = stdout.split("\n")
    assert_equal expected.size, lines.size, "vector count mismatch"

    expected.zip(lines).each_with_index do |(ruby_out, js_out), i|
      assert_equal ruby_out, js_out, "vector #{i} hashes differently in Ruby and JavaScript"
    end
  end

  def expected
    JSON.parse(File.read(RECORDS)).map do |vector|
      Record.digest(payload: vector["payload"], signature: vector["signature"])
    end
  end

  def node? = system("node", "--version", out: File::NULL, err: File::NULL)
end
