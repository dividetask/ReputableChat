# frozen_string_literal: true

module ReputableChat
  module Cryptography
    # The signed payload shapes. Each names its purpose and the origin or room it
    # was made for, so a harvested signature cannot be replayed against another
    # server or replanted in another channel.
    #
    # Every shape but `login` and `private_config` carries `ack`: the hash of
    # the last record its author had seen. That is what makes the set of
    # signatures a chain rather than a pile. See docs/project/chain.md.
    module Payload
      LOGIN          = "reputablechat:login:v1"
      MESSAGE        = "reputablechat:message:v1"
      CONFIG         = "reputablechat:config:v1"
      PRIVATE_CONFIG = "reputablechat:private-config:v1"
      EMOTE          = "reputablechat:emote:v1"
      USER           = "reputablechat:user:v1"
      ATTESTATION    = "reputablechat:attestation:v1"
      ADJUSTMENT     = "reputablechat:adjustment:v1"
      RELEASE        = "reputablechat:release:v1"

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

      # Who somebody is. The genesis record is one of these with every optional
      # field null -- see config/genesis/tom.json.
      #
      # `master_pubkey` and `previous_pubkey` are placeholders for key rotation
      # and are always null for now. They are in the signed shape from the
      # start because adding a field later changes the canonical bytes of every
      # record, which invalidates every signature ever made.
      def user(pubkey:, version:, handle:, bio:, icon:, ack:, issued_at:,
               master_pubkey: nil, previous_pubkey: nil)
        {
          "purpose"         => USER,
          "pubkey"          => pubkey,
          "version"         => version.to_i,
          "handle"          => handle,
          "bio"             => bio,
          "icon"            => icon,
          "master_pubkey"   => master_pubkey,
          "previous_pubkey" => previous_pubkey,
          "ack"             => ack,
          "ts"              => issued_at.to_i
        }
      end

      # What somebody thinks of everyone else.
      #
      # `scores` maps a pubkey to {"reputation" => "0.5", "trust" => "1"}, both
      # decimal strings -- canonical serialization refuses floats, and the
      # Blocked line is `reputation > 0`, which binary floating point cannot be
      # trusted to land on.
      #
      # `derived` is the author's own calculated scores and a cache, nothing
      # more. It carries the hash of the parameters it was computed under,
      # because reputation is subjective and configuration is per-user: without
      # that hash a reader cannot tell whether the numbers mean anything to
      # them, and taking them anyway would mean silently adopting a stranger's
      # settings.
      def attestation(pubkey:, version:, scores:, derived:, ack:, issued_at:)
        {
          "purpose" => ATTESTATION,
          "pubkey"  => pubkey,
          "version" => version.to_i,
          "scores"  => scores,
          "derived" => derived,
          "ack"     => ack,
          "ts"      => issued_at.to_i
        }
      end

      # One change to an attestation between republishes. Re-signing a whole
      # attestation per emote would mean re-uploading an entry for every person
      # the author has ever rated to change one number in it.
      #
      # `base_version` names the attestation this amends and `seq` orders it
      # within that run, both inside the signature, so the server cannot
      # reorder a run or replay one against a later snapshot.
      def adjustment(pubkey:, base_version:, seq:, target:, reputation:, trust:, ack:, issued_at:)
        {
          "purpose"      => ADJUSTMENT,
          "pubkey"       => pubkey,
          "base_version" => base_version.to_i,
          "seq"          => seq.to_i,
          "target"       => target,
          "reputation"   => reputation,
          "trust"        => trust,
          "ack"          => ack,
          "ts"           => issued_at.to_i
        }
      end

      # A published version of the client: a manifest of path => sha256, not an
      # archive. A zip's bytes depend on entry order, timestamps and
      # compression level, so the same source tree hashes differently on two
      # machines -- and a hash that depends on who built it proves nothing.
      #
      # `publisher` is carried so a per-user trusted-developer setting can
      # arrive later without re-signing anything. Nothing consults it yet.
      def release(publisher:, version:, label:, files:, notes:, ack:, issued_at:)
        {
          "purpose"   => RELEASE,
          "publisher" => publisher,
          "version"   => version.to_i,
          "label"     => label,
          "files"     => files,
          "notes"     => notes,
          "ack"       => ack,
          "ts"        => issued_at.to_i
        }
      end

      # `seq` and `prev` chain an author's own messages so that a server cannot
      # silently drop or reorder one without it being detectable. `ack` chains
      # this message to everyone else's records; the two catch different
      # failures and both are kept.
      #
      # `ts` is the client's clock and is attacker-controlled; the server
      # records its own receipt time separately and unsigned.
      #
      # `reply_to` is the record hash of the message being replied to, or nil.
      # Always present so the canonical form does not change shape between a
      # reply and an ordinary message.
      def message(author:, room:, seq:, prev:, body:, ack:, issued_at:, reply_to: nil)
        {
          "purpose"  => MESSAGE,
          "author"   => author,
          "room"     => room,
          "seq"      => seq.to_i,
          "prev"     => prev,
          "reply_to" => reply_to,
          "ack"      => ack,
          "ts"       => issued_at.to_i,
          "body"     => body
        }
      end

      # One person's reaction to one message. `message` is that message's
      # record hash. `room` is carried for the same reason a message carries
      # it: so a reaction cannot be transplanted elsewhere.
      #
      # An emote record is also its own attestation adjustment -- it names the
      # author, the target message and the reaction, which is everything needed
      # to move the author's score for that message's author.
      def emote(author:, room:, message:, emote:, ack:, issued_at:)
        {
          "purpose" => EMOTE,
          "author"  => author,
          "room"    => room,
          "message" => message,
          "emote"   => emote,
          "ack"     => ack,
          "ts"      => issued_at.to_i
        }
      end

      # The owner's own settings and state. The only shape with no `ack`,
      # because nobody else ever sees it, so there is nothing to anchor it to
      # and nobody to prove anything to.
      #
      # Signed, not encrypted -- this is private from other users, not from the
      # server operator, who can read it. Superseded by the encrypted vault;
      # see docs/project/identity.md.
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

      # Superseded by `user` (identity and presentation) and `attestation`
      # (ratings). Kept until the routes that serve it are replaced, so that
      # the running client does not break mid-migration.
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
