# frozen_string_literal: true

require "json"
require "bigdecimal"
require_relative "../cryptography/canonical"
require_relative "../cryptography/record"
require_relative "../cryptography/signature"

module ReputableChat
  module Chain
    # Raised with the reason a record is refused. The message is shown to
    # whoever sent the record, so it names the rule rather than the code.
    class Invalid < StandardError; end

    # One record, parsed and checked against everything the rules say that can
    # be decided from the record alone: its form, its fields and its signature.
    # What needs the record's history -- which keys it may sign with, whether
    # what it spends exists -- is Ledger's.
    #
    # Built from the payload string as it arrived, never from a re-serialized
    # object: the signature and the record hash are over those exact bytes.
    class Record
      PREFIX = "reputablechat"
      TYPES  = %w[attestation heartbeat identity message notice reaction release].freeze
      PART   = /\A[a-z0-9.-]{1,32}\z/
      HASH   = /\A[0-9a-f]{64}\z/
      FILE   = /\A[0-9a-f]{64}\.[a-z0-9]{1,5}\z/
      LANG   = /\A[A-Za-z0-9-]{1,35}\z/
      # A whole part of at least one digit with no leading zeros, and a
      # fraction of one to eighteen digits whose last is not zero; never "-0".
      DECIMAL = /\A-?(0|[1-9][0-9]*)(\.[0-9]{0,17}[1-9])?\z/
      CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/
      EDGE_SPACE = /\A[[:space:]]|[[:space:]]\z/

      ACK_LIMIT       = 16
      HEARTBEAT_BYTES = 1_048_576
      LIST_LIMIT      = 256
      FILE_LIMIT      = 16
      ADJUDICATORS    = 16
      BODY_BYTES      = 16_000
      RULES_BYTES     = 64_000
      TITLE_BYTES     = 280
      HANDLE_BYTES    = 64
      URL_BYTES       = 2_048
      KIND_BYTES      = 64
      TYPE_BYTES      = 128
      SCORES_BYTES    = 1_048_576

      COMMON = %w[type id pubkey mpubkey ack body rules ts target endorse transfer
                  title file url lang].freeze
      OWN = { "identity" => %w[epubkey adjudicators], "attestation" => %w[scores derived],
              "notice" => %w[kind] }.freeze
      HEARTBEAT = %w[type id pubkey mpubkey ack body ts endorse].freeze

      KEY_CHANGE        = "key-change"
      MASTER_KEY_CHANGE = "master-key-change"
      COMPROMISED       = "compromised"
      QUORUM            = "quorum"

      attr_reader :record_hash, :payload, :signature, :fields, :kind, :version, :apps, :signers

      # Ledger's annotations, set as the record joins it.
      attr_accessor :seq, :signer, :contests, :replaced, :beat, :beats

      def self.parse(payload, signature)
        new(payload, signature)
      end

      def initialize(payload, signature)
        @payload = payload
        @signature = signature
        @fields = parse_payload(payload)
        @record_hash = Cryptography::Record.digest(payload: payload, signature: signature)
        check!
      end

      # --- what the rest of the system asks of a record -----------------------

      def [](name) = fields[name]

      def first_declaration? = kind == "identity" && !fields.key?("id")
      def genesis? = first_declaration? && acks.empty?

      # The record hash of the account's first declaration, which is this
      # record's own hash when it is that declaration.
      def account = fields["id"] || record_hash

      def acks = fields["ack"]
      def targets = fields["target"] || []
      def endorses = fields["endorse"] || []
      def transfer = fields["transfer"]
      def notice_kind = kind == "notice" ? fields["kind"] : nil
      def key_change? = [KEY_CHANGE, MASTER_KEY_CHANGE].include?(notice_kind)

      # Which key a key change moves: the working key or the master key.
      def changes_role = { KEY_CHANGE => "pubkey", MASTER_KEY_CHANGE => "mpubkey" }[notice_kind]

      def spends = transfer&.fetch("in", nil) || []
      def issuing? = transfer && !transfer.key?("in")

      # The currency a transfer moves: named, or the author's own when issuing.
      def currency
        return nil unless transfer

        transfer["currency"] || account
      end

      def outputs = transfer&.fetch("out", nil) || []

      def output_to(account_id)
        outputs.find { |o| o["to"] == account_id }
      end

      def app?(name) = apps.first == name

      private

      def invalid(message) = raise(Invalid, message)

      def parse_payload(payload)
        invalid("the payload is not a string") unless payload.is_a?(String)
        invalid("the payload is not UTF-8") unless payload.dup.force_encoding("UTF-8").valid_encoding?

        parsed = JSON.parse(payload)
        invalid("the payload is not a JSON object") unless parsed.is_a?(Hash)

        canonical = begin
          Cryptography::Canonical.dump(parsed)
        rescue ArgumentError
          invalid("the payload holds a floating-point number")
        end
        invalid("the payload is not in canonical form") unless canonical == payload.dup.force_encoding("UTF-8")

        parsed
      rescue JSON::ParserError
        invalid("the payload is not JSON")
      end

      # --- section 1 and 2: the form of every record ----------------------------

      def check!
        check_type!
        check_fields_allowed!
        check_keys!
        check_signature!
        check_ack!
        check_common!
        send("check_#{kind}!")
      end

      def check_type!
        type = fields["type"]
        text!(type, "type", max: TYPE_BYTES, min: 1)
        parts = type.split(":", -1)
        invalid("type has fewer than three parts") if parts.size < 3
        invalid("type does not start with #{PREFIX}") unless parts.first == PREFIX
        parts.drop(1).each do |part|
          invalid("type part #{part.inspect} is not 1 to 32 lowercase letters, digits, dots and hyphens") unless part.match?(PART)
        end
        invalid("#{parts[1]} is not a record type") unless TYPES.include?(parts[1])

        @kind = parts[1]
        @version = parts[2]
        @apps = parts.drop(3)
      end

      def check_fields_allowed!
        allowed = kind == "heartbeat" ? HEARTBEAT : COMMON + OWN.fetch(kind, [])
        extra = fields.keys - allowed
        invalid("a #{kind} record does not carry #{extra.sort.join(', ')}") unless extra.empty?

        %w[type ack body ts].each { |name| invalid("#{name} is required") unless fields.key?(name) }
        invalid("id is required on every record but a first identity declaration") if
          kind != "identity" && !fields.key?("id")
      end

      def check_keys!
        %w[pubkey mpubkey].each do |name|
          next unless fields.key?(name)

          invalid("#{name} is not a signing key") unless signing_key?(fields[name])
        end
        invalid("a record carries pubkey, mpubkey or both") unless fields.key?("pubkey") || fields.key?("mpubkey")
        invalid("a first identity declaration requires pubkey") if first_declaration? && !fields.key?("pubkey")
      end

      # Every carried key the signature verifies against, with the field it
      # was carried in. Ledger decides which of them the account may use.
      def check_signature!
        invalid("signature is not base64url of 64 bytes") unless strict_b64(signature, 64)

        bytes = payload.b
        @signers = %w[pubkey mpubkey].filter_map do |role|
          key = fields[role]
          next unless key

          verify_key = Cryptography::Signature.verify_key(key)
          next unless verify_key

          begin
            verify_key.verify(Cryptography::Signature.decode(signature, 64), bytes)
            [role, key]
          rescue Ed25519::VerifyError
            nil
          end
        end
        invalid("the signature verifies against no key the record carries") if @signers.empty?
      end

      def check_ack!
        ack = fields["ack"]
        hashes!(ack, "ack", max: nil)

        if kind == "heartbeat"
          invalid("a heartbeat's ack is over #{HEARTBEAT_BYTES} bytes") if
            Cryptography::Canonical.dump(ack).bytesize > HEARTBEAT_BYTES
        elsif ack.size > ACK_LIMIT
          invalid("ack names #{ack.size} records; the limit is #{ACK_LIMIT}")
        end

        genesis_shaped = kind == "identity" && !fields.key?("id") && fields.key?("rules")
        invalid("ack is empty in the genesis record and nowhere else") if ack.empty? != genesis_shaped
      end

      def check_common!
        if fields.key?("id")
          invalid("id is not a record hash") unless hash?(fields["id"])
        end
        text!(fields["body"], "body", max: BODY_BYTES, min: 0)

        if fields.key?("rules")
          release_or_genesis = kind == "release" || (kind == "identity" && !fields.key?("id"))
          invalid("rules is allowed on the genesis record and releases only") unless release_or_genesis
          text!(fields["rules"], "rules", max: RULES_BYTES, min: 1)
        end

        invalid("ts is not an integer") unless fields["ts"].is_a?(Integer)
        hashes!(fields["target"], "target", max: LIST_LIMIT) if fields.key?("target")
        hashes!(fields["endorse"], "endorse", max: LIST_LIMIT) if fields.key?("endorse")
        check_transfer! if fields.key?("transfer")

        text!(fields["title"], "title", max: TITLE_BYTES, min: 1) if fields.key?("title")
        check_files! if fields.key?("file")
        if fields.key?("url")
          text!(fields["url"], "url", max: URL_BYTES, min: 1)
          invalid("url holds whitespace") if fields["url"].match?(/[[:space:]]/)
        end
        invalid("lang is not 1 to 35 letters, digits and hyphens") if
          fields.key?("lang") && !(fields["lang"].is_a?(String) && fields["lang"].match?(LANG))
      end

      def check_files!
        files = fields["file"]
        invalid("file is not a list") unless files.is_a?(Array)
        invalid("file holds more than #{FILE_LIMIT}") if files.size > FILE_LIMIT
        invalid("file repeats a file") unless files.uniq.size == files.size
        files.each do |f|
          invalid("#{f.inspect} is not a file: a SHA-256 in hex and an extension") unless f.is_a?(String) && f.match?(FILE)
        end
      end

      def check_transfer!
        t = fields["transfer"]
        invalid("transfer is not an object") unless t.is_a?(Hash)
        extra = t.keys - %w[currency in out]
        invalid("transfer does not carry #{extra.sort.join(', ')}") unless extra.empty?
        invalid("transfer must hold in, out or both") unless t.key?("in") || t.key?("out")

        if t.key?("in")
          invalid("a transfer that spends names its currency") unless t.key?("currency")
          hashes!(t["in"], "transfer in", max: LIST_LIMIT)
        else
          invalid("currency is omitted only when issuing, and in with it") if t.key?("currency")
        end
        invalid("currency is not an account ID") if t.key?("currency") && !hash?(t["currency"])

        if t.key?("out")
          out = t["out"]
          invalid("out is not a list") unless out.is_a?(Array)
          invalid("out holds 1 to #{LIST_LIMIT} outputs") unless out.size.between?(1, LIST_LIMIT)
          out.each do |o|
            invalid("an output holds value and to, and nothing else") unless o.is_a?(Hash) && o.keys.sort == %w[to value]
            invalid("an output's to is not an account ID") unless hash?(o["to"])
            invalid("an output's value is not a decimal greater than zero") unless decimal?(o["value"]) && BigDecimal(o["value"]).positive?
          end
          tos = out.map { |o| o["to"] }
          invalid("out is not sorted by to") unless tos == tos.sort
          invalid("out pays one account twice") unless tos.uniq.size == tos.size
        end

        return unless t.key?("in") && t.key?("out")

        # The values must equal what is spent; that needs the spent outputs, so
        # it is Ledger's. Here only that there is something to compare.
      end

      # --- section 3 onwards: each record type ------------------------------------

      def check_identity!
        text!(fields["title"], "the handle", max: HANDLE_BYTES, min: 1)
        if fields.key?("epubkey")
          invalid("epubkey is not an encryption key") unless strict_b64(fields["epubkey"], 32)
        end
        return unless fields.key?("adjudicators")

        list = fields["adjudicators"]
        invalid("adjudicators is not a list") unless list.is_a?(Array)
        invalid("adjudicators holds more than #{ADJUDICATORS}") if list.size > ADJUDICATORS
        invalid("adjudicators repeats an account") unless list.uniq.size == list.size
        list.each { |a| invalid("an adjudicator is not an account ID") unless hash?(a) }
      end

      def check_attestation!
        invalid("an attestation requires scores") unless fields.key?("scores")
        size = %w[scores derived].sum do |name|
          next 0 unless fields.key?(name)

          scores!(fields[name], name)
          Cryptography::Canonical.dump(fields[name]).bytesize
        end
        invalid("scores and derived are over #{SCORES_BYTES} bytes together") if size > SCORES_BYTES
      end

      def check_message!; end

      def check_reaction!
        invalid("a reaction requires target") if targets.empty?
      end

      def check_notice!
        text!(fields["kind"], "kind", max: KIND_BYTES, min: 1)

        case notice_kind
        when KEY_CHANGE, MASTER_KEY_CHANGE
          invalid("a #{notice_kind}'s body is the new key and nothing else") unless signing_key?(fields["body"])
        when COMPROMISED
          invalid("a compromised notice requires target") if targets.empty?
        when QUORUM
          invalid("a quorum's target names exactly one record") unless targets.size == 1
        end
      end

      def check_release!
        invalid("a release requires rules") unless fields.key?("rules")
      end

      def check_heartbeat!
        invalid("a heartbeat's body is empty") unless fields["body"] == ""
      end

      # --- the kinds of value, section 1 ---------------------------------------------

      def text!(value, name, max:, min:)
        invalid("#{name} is not text") unless value.is_a?(String) && value.valid_encoding?
        invalid("#{name} holds a control character") if value.match?(CONTROL)
        invalid("#{name} has surrounding whitespace") if value.match?(EDGE_SPACE)
        invalid("#{name} is not #{min} to #{max} bytes") unless value.bytesize.between?(min, max)
      end

      def hashes!(value, name, max:)
        invalid("#{name} is not a list of record hashes") unless value.is_a?(Array) && value.all? { |h| hash?(h) }
        invalid("#{name} is not sorted") unless value == value.sort
        invalid("#{name} repeats a record") unless value.uniq.size == value.size
        invalid("#{name} names more than #{max}") if max && value.size > max
      end

      def scores!(value, name)
        invalid("#{name} is not a map") unless value.is_a?(Hash)
        value.each do |id, entry|
          invalid("#{name} is keyed by #{id.inspect}, not a record hash") unless hash?(id)
          invalid("a #{name} entry holds reputation and trust") unless entry.is_a?(Hash) && entry.keys.sort == %w[reputation trust]
          %w[reputation trust].each do |field|
            v = entry[field]
            invalid("#{field} is not a decimal from -1 to +1") unless decimal?(v) && BigDecimal(v).abs <= 1
          end
        end
      end

      def hash?(value) = value.is_a?(String) && value.match?(HASH)
      def decimal?(value) = value.is_a?(String) && value.match?(DECIMAL) && value != "-0"
      def signing_key?(value) = !strict_b64(value, 32).nil?

      # Exactly one spelling: unpadded base64url of the stated length, which
      # re-encodes to itself.
      def strict_b64(value, bytes)
        raw = Cryptography::Signature.decode(value, bytes)
        raw && Cryptography::Signature.encode(raw) == value ? raw : nil
      end
    end
  end
end
