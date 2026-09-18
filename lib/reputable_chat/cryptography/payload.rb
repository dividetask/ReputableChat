# frozen_string_literal: true

module ReputableChat
  module Cryptography
    # The signed payload shapes. Each names its purpose and the origin or room it
    # was made for, so a harvested signature cannot be replayed against another
    # server or replanted in another channel.
    module Payload
      LOGIN          = "reputablechat:login:v1"
      MESSAGE        = "reputablechat:message:v1"
      CONFIG         = "reputablechat:config:v1"
      PRIVATE_CONFIG = "reputablechat:private-config:v1"
      EMOTE          = "reputablechat:emote:v1"

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
      # `reply_to` is the signature of the message being replied to, or nil.
      # Always present so the canonical form does not change shape between a
      # reply and an ordinary message.
      def message(author:, room:, seq:, prev:, body:, issued_at:, reply_to: nil)
        {
          "purpose"  => MESSAGE,
          "author"   => author,
          "room"     => room,
          "seq"      => seq.to_i,
          "prev"     => prev,
          "reply_to" => reply_to,
          "ts"       => issued_at.to_i,
          "body"     => body
        }
      end

      # `version` is a monotonic counter. Without it the server could serve an
      # old copy of someone's config to hide a report from you and the
      # signature would still verify perfectly.
      # One person's reaction to one message. `message` is that message's
      # signature, which is unique. `room` is carried for the same reason a
      # message carries it: so a reaction cannot be transplanted elsewhere.
      def emote(author:, room:, message:, emote:, issued_at:)
        {
          "purpose" => EMOTE,
          "author"  => author,
          "room"    => room,
          "message" => message,
          "emote"   => emote,
          "ts"      => issued_at.to_i
        }
      end

      # The owner's own settings and state. Signed for the same reason the
      # public config is: the server holds it so it cannot be lost, and the
      # signature is what proves it came back unaltered.
      #
      # Signed, not encrypted -- this is private from other users, not from the
      # server operator, who can read it. Making it opaque to the server means
      # encrypting it under a key derived from the seed.
      def private_config(pubkey:, version:, settings:, voted:, issued_at:)
        {
          "purpose"  => PRIVATE_CONFIG,
          "pubkey"   => pubkey,
          "version"  => version.to_i,
          "settings" => settings,
          "voted"    => voted,
          "ts"       => issued_at.to_i
        }
      end

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
