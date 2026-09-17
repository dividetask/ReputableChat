# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/crypto/canonical"
require "open3"

# The browser signs bytes and the server verifies bytes. If these two
# serializers ever disagree by even one character, every signature in the
# system silently stops verifying. This test is the thing that catches that.
class CanonicalParitySpec < Minitest::Test
  Canonical = ReputableChat::Crypto::Canonical

  FIXTURES = File.expand_path("fixtures/canonical_vectors.json", __dir__)
  SCRIPT   = File.expand_path("canonical_parity.mjs", __dir__)

  def vectors = JSON.parse(File.read(FIXTURES))

  def test_ruby_and_javascript_agree_byte_for_byte
    skip "node is not installed" unless node?

    stdout, stderr, status = Open3.capture3("node", SCRIPT, binmode: true)
    flunk "node failed: #{stderr}" unless status.success?

    # Compared as bytes, not as encoding-tagged strings: what gets signed is
    # bytes, and node's stdout arrives without Ruby's UTF-8 tag.
    js_lines = stdout.split("\n".b).map(&:b)
    rb_lines = vectors.map { |v| Canonical.bytes(v) }

    assert_equal rb_lines.size, js_lines.size, "vector count mismatch"

    rb_lines.zip(js_lines).each_with_index do |(ruby_out, js_out), i|
      assert_equal ruby_out, js_out,
                   "vector #{i} serializes to different bytes in Ruby and JavaScript:\n" \
                   "  ruby: #{ruby_out.inspect}\n  js:   #{js_out.inspect}"
    end
  end

  def test_keys_are_sorted_and_whitespace_free
    assert_equal '{"a":2,"z":1}', Canonical.dump({ "z" => 1, "a" => 2 })
  end

  def test_nested_structures_are_sorted_throughout
    assert_equal '{"outer":{"a":1,"b":{"c":2,"d":3}}}',
                 Canonical.dump({ "outer" => { "b" => { "d" => 3, "c" => 2 }, "a" => 1 } })
  end

  def test_floats_are_refused
    assert_raises(ArgumentError) { Canonical.dump({ "x" => 1.5 }) }
  end

  def node? = system("node", "--version", out: File::NULL, err: File::NULL)
end
