# frozen_string_literal: true

require "digest"
require "json"
require_relative "canonical"

module Agnostic
  # A signed record: the payload exactly as it arrived, and the signature over
  # it. The payload string is what is hashed, stored and served; the parsed
  # fields are only for reading, and are never serialized back.
  class Record
    HASH = /\A[0-9a-f]{64}\z/

    attr_reader :payload, :signature
    # Set from the store, for records already on this server's chain.
    attr_accessor :seq, :signer, :signer_field, :subject, :beat_index, :facts

    def self.from_wire(object)
      raise ArgumentError, "a record is an object with payload and signature" unless object.is_a?(Hash)

      new(payload: object["payload"], signature: object["signature"])
    end

    def self.hash?(value) = value.is_a?(String) && value.match?(HASH)

    def initialize(payload:, signature:)
      @payload = payload
      @signature = signature
      @facts = {}
    end

    # The record hash: SHA-256 over the canonical payload, a newline and the
    # signature (section 1). Neither half can hold a raw newline, so one pair
    # of strings gives any one hash; nil when either half is not a string or
    # holds one. Named digest because Object#hash is Ruby's own.
    def digest
      return @digest if defined?(@digest)

      @digest = (Digest::SHA256.hexdigest("#{payload}\n#{signature}".b) if well_formed_halves?)
    end

    def well_formed_halves?
      payload.is_a?(String) && signature.is_a?(String) && !payload.include?("\n") && !signature.include?("\n")
    end

    # The parsed payload, or raises Canonical::NotCanonical.
    def fields = @fields ||= Canonical.parse(payload)

    def [](key) = fields[key]

    def key?(key) = fields.key?(key)

    def type_parts = self["type"].is_a?(String) ? self["type"].split(":", -1) : []

    def kind = type_parts[1]

    def version = type_parts[2]

    def notice_kind = kind == "notice" && self["kind"].is_a?(String) ? self["kind"] : nil

    def ack = list("ack")

    def target = list("target")

    def endorse = list("endorse")

    def transfer = self["transfer"].is_a?(Hash) ? self["transfer"] : nil

    def ts = self["ts"]

    # An identity declaration without an id is a first declaration: its hash
    # becomes the account ID.
    def first_declaration? = kind == "identity" && !key?("id")

    def account = first_declaration? ? digest : self["id"]

    def heartbeat? = kind == "heartbeat"

    def release? = kind == "release"

    def to_wire = { "payload" => payload, "signature" => signature, "hash" => digest }

    private

    def list(key) = self[key].is_a?(Array) ? self[key] : []
  end
end
