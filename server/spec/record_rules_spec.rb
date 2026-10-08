# frozen_string_literal: true

require_relative "spec_helper"

# Sections 1 to 10, the checks that need nothing but the record itself.
class RecordRulesSpec < Minitest::Test
  include ChainHelpers

  def setup
    setup_chain
    @bob = declare("bob").digest
  end

  def note(**extra) = post("bob", @bob, ack: [@bob], **extra)

  def test_a_well_formed_message_is_accepted
    accept(note(body: "Hello."))
  end

  # --- section 1, records -----------------------------------------------------

  def test_the_record_hash_is_sha256_over_payload_newline_signature
    record = note
    assert_equal Digest::SHA256.hexdigest("#{record.payload}\n#{record.signature}"), record.digest
  end

  def test_a_payload_that_is_not_canonical_is_refused
    canonical = note.payload
    {
      "whitespace" => canonical.sub(",", ", "),
      "unsorted keys" => canonical.sub('{"ack"', '{"zz":1,"ack"'),
      "a duplicate key" => canonical.sub("{", '{"body":"x",'),
      "an escaped character canonical form writes raw" => canonical.sub('"body":""') { "\"body\":\"\\u00e9\"" }
    }.each do |what, payload|
      refuse(sign_raw("bob", payload), /canonical|JSON/)
    rescue Minitest::Assertion => e
      raise e.exception("#{what}: #{e.message}")
    end
  end

  def test_a_floating_point_number_is_refused
    refuse(sign_raw("bob", note.payload.sub(/"ts":\d+/, '"ts":1.5')), /floating-point/)
  end

  def test_an_integer_javascript_cannot_represent_is_refused
    refuse(sign_raw("bob", note.payload.sub(/"ts":\d+/, '"ts":9007199254740993')), /JavaScript/)
  end

  def test_a_signature_by_neither_carried_key_is_refused
    forged = Agnostic::Record.new(payload: note.payload, signature: Agnostic::Keys.sign(key("mallory"), note.payload))
    refuse(forged, /verifies against no key/)
  end

  def test_a_padded_or_misspelled_key_is_refused
    refuse(note(pubkey: "#{pub('bob')}="), /signing key/)
  end

  def test_text_holds_no_control_characters_but_tab_newline_and_return
    accept(note(body: "one\ttwo\nthree\r\nfour"))
    refuse(note(body: "bell\u0007"), /body must be Text/)
  end

  def test_text_has_its_surrounding_whitespace_removed
    refuse(note(body: " padded"), /body must be Text/)
    refuse(note(body: "padded "), /body must be Text/)
  end

  # --- section 2, common fields -----------------------------------------------

  def test_the_type_names_reputablechat_a_record_type_and_a_version
    refuse(note(type: "reputablechat:message"), /type must be/)
    refuse(note(type: "reputablechat:gossip:#{version}"), /type must be/)
    refuse(note(type: "otherchat:message:#{version}"), /type must be/)
    refuse(note(type: "reputablechat:message:#{version}:Forum"), /type must be/)
    accept(note(type: "reputablechat:message:#{version}:forum:extra"))
  end

  def test_a_version_this_server_does_not_implement_is_refused
    refuse(note(type: "reputablechat:message:v0.002"), /not one this server implements/)
  end

  def test_every_record_but_a_first_declaration_carries_an_account_id
    record = sign("bob", { "ack" => [@bob], "type" => "reputablechat:message:#{version}" })
    refuse(record, /id must be an account ID/)
  end

  def test_a_first_declaration_carries_pubkey
    record = sign("carol", { "ack" => [tim], "title" => "Carol", "type" => "reputablechat:identity:#{version}",
                             "mpubkey" => pub("carol") }, field: "mpubkey")
    refuse(record, /must carry pubkey/)
  end

  def test_ack_is_sorted_with_no_duplicates
    refuse(sign("bob", { "ack" => [@bob, tim].sort.reverse, "id" => @bob }), /sorted/)
    refuse(sign("bob", { "ack" => [@bob, @bob], "id" => @bob }), /sorted/)
  end

  def test_an_ordinary_record_acks_at_most_16
    many = Array.new(17) { |i| Digest::SHA256.hexdigest(i.to_s) }.sort
    refuse(post("bob", @bob, ack: many), /over the limit of 16/)
  end

  def test_only_the_genesis_has_an_empty_ack
    refuse(post("bob", @bob, ack: []), /empty ack/)
  end

  def test_body_is_required_and_at_most_16000_bytes
    refuse(sign_raw("bob", Agnostic::Canonical.dump(note.fields.except("body"))), /body/)
    refuse(note(body: "x" * 16_001), /body/)
  end

  def test_only_the_genesis_and_releases_carry_rules
    refuse(note(rules: "My own rules"), /only the genesis record and releases/)
  end

  def test_optional_fields_have_their_forms
    refuse(note(title: ""), /title/)
    refuse(note(url: "https://example.com/a b"), /url/)
    refuse(note(lang: "en_GB"), /lang/)
    refuse(note(file: ["not-a-file.png"]), /file/)
    refuse(note(target: [@bob, @bob]), /target/)
    accept(note(title: "T", url: "https://example.com/", lang: "pt-BR",
                   file: ["#{'a' * 64}.png"], target: [@bob]))
  end

  # --- sections 3 to 10 -------------------------------------------------------

  def test_an_identity_declaration_has_a_handle_of_1_to_64_bytes
    refuse(declare_record("dave", title: "x" * 65), /handle/)
  end

  def test_adjudicators_are_at_most_16_account_ids
    refuse(declare_record("dave", adjudicators: Array.new(17) { |i| Digest::SHA256.hexdigest(i.to_s) }), /adjudicators/)
  end

  def test_an_attestation_rates_with_decimals_from_minus_one_to_one
    attest = ->(score) { post("bob", @bob, ack: [@bob], type: "reputablechat:attestation:#{version}", scores: { tim => score }) }
    accept(attest.({ "reputation" => "0.5", "trust" => "1" }))
    refuse(attest.({ "reputation" => "0.50", "trust" => "1" }), /scores entry/)
    refuse(attest.({ "reputation" => ".5", "trust" => "1" }), /scores entry/)
    refuse(attest.({ "reputation" => "-0", "trust" => "1" }), /scores entry/)
    refuse(attest.({ "reputation" => "1.5", "trust" => "1" }), /scores entry/)
    refuse(attest.({ "reputation" => "0.5" }), /scores entry/)
  end

  def test_an_attestation_requires_scores
    refuse(post("bob", @bob, ack: [@bob], type: "reputablechat:attestation:#{version}"), /requires scores/)
  end

  def test_a_reaction_requires_target
    refuse(post("bob", @bob, ack: [@bob], type: "reputablechat:reaction:#{version}", body: "+1"), /requires target/)
  end

  def test_a_notice_requires_a_kind
    refuse(post("bob", @bob, ack: [@bob], type: "reputablechat:notice:#{version}"), /requires kind/)
  end

  def test_a_notice_of_a_kind_the_rules_do_not_define_is_accepted
    accept(post("bob", @bob, ack: [@bob], type: "reputablechat:notice:#{version}", kind: "outage",
                             body: "Down for an hour."))
  end

  def test_a_key_change_body_is_the_new_key_and_nothing_else
    refuse(post("bob", @bob, ack: [@bob], type: "reputablechat:notice:#{version}", kind: "key-change",
                             body: "#{pub('bob2')} please"), /body is the new key/)
  end

  def test_a_heartbeat_carries_nothing_beyond_the_common_fields_and_endorse
    beat = ->(**extra) { post("bob", @bob, ack: [@bob], type: "reputablechat:heartbeat:#{version}", **extra) }
    refuse(beat.(title: "Beat"), /beyond what it may hold/)
    refuse(beat.(body: "thump"), /body is empty/)
    accept(beat.(endorse: [@bob]))
  end

  def test_a_transfer_names_a_currency_exactly_when_it_spends
    refuse(note(transfer: { "in" => [@bob], "out" => [{ "to" => @bob, "value" => "1" }] }), /currency and in go together/)
    refuse(note(transfer: { "currency" => tim, "out" => [{ "to" => @bob, "value" => "1" }] }), /currency and in go together/)
    refuse(note(transfer: {}), /in, out or both/)
  end

  def test_outputs_are_positive_decimals_sorted_by_account
    out = ->(*entries) { declare_record("dave", transfer: { "out" => entries }) }
    refuse(out.({ "to" => tim, "value" => "0" }), /greater than zero/)
    refuse(out.({ "to" => tim, "value" => 1 }), /greater than zero/)
    refuse(out.(*[{ "to" => @bob, "value" => "1" }, { "to" => tim, "value" => "1" }].sort_by { |o| o["to"] }.reverse),
           /sorted by to/)
  end

  private

  def declare_record(name, **extra)
    sign(name, { "ack" => [tim], "title" => name.capitalize, "type" => "reputablechat:identity:#{version}" }
                 .merge(extra.transform_keys(&:to_s)))
  end
end
