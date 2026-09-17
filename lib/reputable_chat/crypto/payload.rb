# frozen_string_literal: true

module ReputableChat
  module Crypto
    # The signed payload shapes. Each names its purpose and the origin or room it
    # was made for, so a harvested signature cannot be replayed against another
    # server or replanted in another channel.
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
      # `profile` is signed alongside the ratings so a display name, bio and
      # icon cannot be altered by the server. The icon is a content-addressed
      # filename, so what is signed is really the image itself.
      def config(pubkey:, version:, profile:, ratings:, issued_at:)
        {
          "purpose" => CONFIG,
          "pubkey"  => pubkey,
          "version" => version.to_i,
          "profile" => profile,
          "ratings" => ratings,
          "ts"      => issued_at.to_i
        }
      end
    end
  end
end
