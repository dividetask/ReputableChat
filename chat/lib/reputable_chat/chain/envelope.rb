# frozen_string_literal: true

require "json"
require_relative "../cryptography/record"

module ReputableChat
  module Chain
    # A record as the chat reads it: what it is and whose, enough to decide
    # whether the chat cares and to show it. Not a judgement -- whether a
    # record is valid is the agnostic server's to say, and nothing here
    # checks the rules.
    class Envelope
      class Unreadable < StandardError; end

      # The notice kinds the rules give meaning to (section 7).
      CHAIN_NOTICES = %w[compromised key-change master-key-change quorum].freeze
      # Records about the chain itself, which the chat keeps whatever app
      # they came from.
      CHAIN_KINDS = %w[identity attestation heartbeat release].freeze
      CHAT = "chat"

      attr_reader :payload, :signature, :fields, :record_hash

      def self.parse(payload, signature)
        new(payload, signature)
      end

      def initialize(payload, signature)
        raise Unreadable, "payload is the record's canonical JSON, as a string" unless payload.is_a?(String)
        raise Unreadable, "signature is required" unless signature.is_a?(String)

        @payload = payload
        @signature = signature
        @fields = JSON.parse(payload)
        raise Unreadable, "the payload is not a JSON object" unless @fields.is_a?(Hash)

        @record_hash = Cryptography::Record.digest(payload: payload, signature: signature)
      rescue JSON::ParserError
        raise Unreadable, "the payload is not JSON"
      rescue Cryptography::Record::MalformedPayload => e
        raise Unreadable, e.message
      end

      def [](name) = fields[name]

      def type_parts = fields["type"].is_a?(String) ? fields["type"].split(":", -1) : []
      def kind = type_parts[1]
      def apps = type_parts.drop(3)
      def app?(name) = apps.first == name
      def notice_kind = kind == "notice" ? fields["kind"] : nil

      def first_declaration? = kind == "identity" && !fields.key?("id")
      def account = fields["id"] || record_hash
      def targets = fields["target"].is_a?(Array) ? fields["target"] : []

      # Whether the chat keeps this record: anything about the chain itself,
      # and the chat's own records. Another app's records are not the chat's
      # business, though they reach it anyway inside other records' histories.
      def relevant?(chat_notices)
        return true if CHAIN_KINDS.include?(kind)
        return true if kind == "notice" && (CHAIN_NOTICES.include?(notice_kind) || chat_notices.include?(notice_kind))

        %w[message reaction].include?(kind) && app?(CHAT)
      end
    end
  end
end
