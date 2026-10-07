# frozen_string_literal: true

require_relative "spec_helper"
require "set"

# Three rules in this document were written down twice and then edited in one
# place only. Each time, the two copies disagreed about which records are valid,
# and nothing noticed: the duplicate was a paraphrase, so it did not even read
# as a copy. These assertions are about the text, because the failure is in the
# text -- a rule with two homes drifts, and the drift decides whether an
# implementer rejects a record or accepts it.
class RulesTextSpec < Minitest::Test
  RULES = File.expand_path("../docs/project/rules/v0.001.md", __dir__)

  NORMATIVE = /\b(invalid|refused|must|may only|valid only if|may not|cannot|never|is void)\b/i

  # Words that carry no subject, so two sentences sharing only these are not
  # saying the same thing.
  COMMON = %w[a an the of to in is are it its that this and or for with as by on be been
              which whatever where when what any all both each no not nothing one two
              they their there so such than then from has have holds other others does
              do at if but only also more most same own very will would can could].to_set

  # Where each rule lives. Everything else may point at it by section, but must
  # not restate it: a second statement is the thing that drifts.
  HOMES = {
    "the definition of history"      => [/A record's history is/, 1],
    "what makes a record valid"      => [/Whether a record is valid is decided/, 1],
    "the ack limit"                  => [/at most 16, or in a heartbeat/, 2],
    "which keys a record may sign with" => [/must be signed with one of/, 2],
    "the contest"                    => [/contests that change|change replacing it/, 2],
    "who may change the master key"  => [/Signed with the current master key/, 7],
    "what conflicts"                 => [/conflict when both change the same key/, 8],
    "when an account is disputed"    => [/An account is disputed, as seen by a record/, 8],
    "what a quorum may name"         => [/quorum is valid only if|one a quorum may confirm/, 7],
    "the heartbeat interval"         => [/at least 480 seconds after/, 10],
    "the orphan rule"                => [/is orphaned by a heartbeat/, 10]
  }.freeze

  def test_no_rule_is_stated_in_two_places
    pairs = []
    normative.combination(2) do |a, b|
      x = subject_words(a)
      y = subject_words(b)
      next if x.size < 6 || y.size < 6

      overlap = (x & y).size.fdiv((x | y).size)
      pairs << [overlap, a, b] if overlap >= 0.4
    end

    assert_empty pairs.map { |o, a, b| format("%.2f: %s\n          %s", o, clip(a), clip(b)) },
                 "these read as one rule written twice"
  end

  def test_each_rule_is_stated_in_the_section_it_belongs_to
    HOMES.each do |rule, (pattern, section)|
      hits = sections.select { |_, body| body.match?(pattern) }.keys
      assert_equal [section], hits,
                   "#{rule} should be stated in section #{section} alone, found in #{hits.inspect}"
    end
  end

  def test_every_section_a_rule_points_at_exists
    numbers = text.scan(/\(?section (\d+)\)?/i).flatten.map(&:to_i).uniq
    refute_empty numbers, "the rules cross-reference their own sections"
    (numbers - sections.keys).each { |n| flunk "a rule points at section #{n}, which does not exist" }
  end

  # A merge left conflict markers in this file and every assertion here passed,
  # because none of them looks at anything but normative sentences and section
  # numbers. A document that still has both sides of an edit in it says two
  # things at once, which is the failure the rest of this spec is about.
  def test_the_document_holds_no_unresolved_merge
    %w[<<<<<<< ======= >>>>>>>].each do |marker|
      refute_includes text, "\n#{marker}", "an unresolved merge is still in the document"
    end
  end

  def test_the_sections_are_numbered_without_a_gap
    assert_equal (1..sections.keys.max).to_a, sections.keys.sort
  end

  private

  def text = @text ||= File.read(RULES, encoding: "UTF-8")

  # Section number => its body, so a rule can be located rather than just found.
  def sections
    @sections ||= text.split(/^(\d+)\. [A-Z][A-Z ]+$/).then do |parts|
      parts.drop(1).each_slice(2).to_h { |number, body| [number.to_i, body] }
    end
  end

  def normative
    @normative ||= text.split(/\n\n+/).reject { |para| para.start_with?("```") }
                       .flat_map { |para| para.gsub(/\s+/, " ").strip.split(/(?<=[.?!])\s+(?=[A-Z("`])/) }
                       .select { |s| s.match?(NORMATIVE) && s.split.size >= 8 }
  end

  def subject_words(sentence) = sentence.downcase.scan(/[a-z][a-z-]+/).to_set - COMMON
  def clip(sentence) = sentence[0, 120]
end
