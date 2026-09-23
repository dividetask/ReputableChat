# frozen_string_literal: true

require "digest"
require_relative "canonical"

module ReputableChat
  module Cryptography
    # A record's identity on the chain: the hash of its canonical payload and
    # its signature together.
    #
    # `ack`, `reply_to` and an emote's `message` field all name one of these.
    # Never a signature: a signature identifies a payload, while a record hash
    # identifies the whole record, signature included, which is what a link has
    # to cover if it is going to be tamper-evident.
    #
    # Must agree with public/js/record.js -- spec/record_parity_spec.rb is what
    # catches it if it ever does not.
    module Record
      DOMAIN    = "reputablechat:record:v1"
      SEPARATOR = "\n"
      HEX       = /\A[0-9a-f]{64}\z/

      class MalformedPayload < StandardError; end

      module_function

      # Takes the canonical payload as a String wherever one is already to
      # hand. The server stores the bytes exactly as they arrived and hashes
      # those; re-serializing a parsed payload server-side is the one habit
      # guaranteed to break a signature eventually.
      def digest(payload:, signature:)
        canonical = payload.is_a?(String) ? payload : Canonical.dump(payload)

        # The separators are unambiguous rather than merely conventional:
        # canonical JSON can never hold a raw newline (JSON escapes one inside
        # a string to the two characters \n, and there is no whitespace between
        # tokens) and base64url has none either. So exactly one pair of strings
        # produces any given hash input. Checked rather than assumed, because
        # the claim is load-bearing and costs one scan to keep honest.
        raise MalformedPayload, "canonical payload contains a newline" if canonical.include?(SEPARATOR)
        raise MalformedPayload, "signature contains a newline" if signature.to_s.include?(SEPARATOR)

        Digest::SHA256.hexdigest(
          [DOMAIN, canonical, signature].join(SEPARATOR).b
        )
      end

      def valid?(value) = value.is_a?(String) && value.match?(HEX)
    end
  end
end
