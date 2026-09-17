# frozen_string_literal: true

module ReputableChat
  module Crypto
    # The shapes that get signed, and their domain separation strings.
    #
    # Every signed payload names its own purpose and the origin it was made
    # for. Without those, a signature harvested by one server could be replayed
    # against another to authenticate as that user, or a message lifted from
    # one room could be replanted in a different one. Both cost nothing now and
    # are impossible to add later without invalidating every signature already
    # in the network.
    module Payload
      LOGIN   = "reputablechat:login:v1"
      MESSAGE = "reputablechat:message:v1"
      CONFIG  = "reputablechat:config:v1"

      module_function

      def login(pubkey:, nonce:, origin:, issued_at:)
        {
          "purpose" => LOGIN,
          "pubkey"  => pubkey,
          "nonce"   => nonce,
          "origin"  => origin,
          "ts"      => issued_at.to_i
        }
      end

      # `seq` and `prev` chain an author's messages so that a server cannot
      # silently drop or reorder one without it being detectable. `ts` is the
      # client's clock and is attacker-controlled; the server records its own
      # receipt time separately and unsigned.
      def message(author:, room:, seq:, prev:, body:, issued_at:)
        {
          "purpose" => MESSAGE,
          "author"  => author,
          "room"    => room,
          "seq"     => seq.to_i,
          "prev"    => prev,
          "ts"      => issued_at.to_i,
          "body"    => body
        }
      end

      # `version` is a monotonic counter. Without it the server could serve an
      # old copy of someone's config to hide a report from you and the
      # signature would still verify perfectly.
      def config(pubkey:, version:, ratings:, issued_at:)
        {
          "purpose" => CONFIG,
          "pubkey"  => pubkey,
          "version" => version.to_i,
          "ratings" => ratings,
          "ts"      => issued_at.to_i
        }
      end
    end
  end
end
