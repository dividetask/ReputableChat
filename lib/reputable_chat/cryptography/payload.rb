# frozen_string_literal: true

module ReputableChat
  module Cryptography
    # The signed payload shapes. Each names its purpose and the origin or room it
    # was made for, so a harvested signature cannot be replayed against another
    # server or replanted in another channel.
    #
    # Every shape but `login` and `vault` carries `ack`: the hash of the last
    # record its author had seen. That is what makes the set of
    # signatures a chain rather than a pile. See docs/project/chain.md.
    #
    # The account that signed a record is always `pubkey`. It was `author` on a
    # message and `publisher` on a release, for the same field -- and the role
    # words were the trouble, since one account authors a message and publishes
    # a release. A key is a key.
    #
    # They also carry `note`: free text the software never reads, for a person
    # browsing the raw chain. It is signed like everything else, so it cannot be
    # added or altered after the fact, and it is deliberately inert -- nothing
    # branches on it, so nothing can be smuggled through it by writing something
    # that reads like a directive. Anything that renders it treats it as text,
    # never markup.
    #
    # Always present, null when unused. Adding a field later changes the
    # canonical bytes of every record and invalidates every signature ever made,
    # so the slot exists from the start.
    module Payload
      LOGIN          = "reputablechat:login:v1"
      MESSAGE        = "reputablechat:message:v1"
      EMOTE          = "reputablechat:emote:v1"
      IDENTITY       = "reputablechat:identity:v1"
      ATTESTATION    = "reputablechat:attestation:v1"
      ADJUSTMENT     = "reputablechat:adjustment:v1"
      RELEASE        = "reputablechat:release:v1"
      NOTICE         = "reputablechat:notice:v1"
      VAULT          = "reputablechat:vault:v1"

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

      # An identity declaration: who somebody is, in their own words and under
      # their own signature. The genesis record is one of these with every optional
      # field null -- see config/genesis/tim.json.
      #
      # `master_pubkey` and `previous_pubkey` are placeholders for key rotation
      # and are always null for now. They are in the signed shape from the
      # start because adding a field later changes the canonical bytes of every
      # record, which invalidates every signature ever made.
      def identity(pubkey:, revision:, handle:, bio:, icon:, ack:, issued_at:,
               master_pubkey: nil, previous_pubkey: nil, note: nil)
        {
          "purpose"         => IDENTITY,
          "pubkey"          => pubkey,
          "revision"         => revision.to_i,
          "handle"          => handle,
          "bio"             => bio,
          "icon"            => icon,
          "master_pubkey"   => master_pubkey,
          "previous_pubkey" => previous_pubkey,
          "ack"             => ack,
          "note"            => note,
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
      def attestation(pubkey:, revision:, scores:, derived:, ack:, issued_at:, note: nil)
        {
          "purpose" => ATTESTATION,
          "pubkey"  => pubkey,
          "revision" => revision.to_i,
          "scores"  => scores,
          "derived" => derived,
          "ack"     => ack,
          "note"    => note,
          "ts"      => issued_at.to_i
        }
      end

      # One change to an attestation between republishes. Re-signing a whole
      # attestation per emote would mean re-uploading an entry for every person
      # the author has ever rated to change one number in it.
      #
      # `base_revision` names the attestation this amends and `seq` orders it
      # within that run, both inside the signature, so the server cannot
      # reorder a run or replay one against a later snapshot.
      def adjustment(pubkey:, base_revision:, seq:, target:, reputation:, trust:, ack:,
                     issued_at:, note: nil)
        {
          "purpose"      => ADJUSTMENT,
          "pubkey"       => pubkey,
          "base_revision" => base_revision.to_i,
          "seq"          => seq.to_i,
          "target"       => target,
          "reputation"   => reputation,
          "trust"        => trust,
          "ack"          => ack,
          "note"         => note,
          "ts"           => issued_at.to_i
        }
      end

      # A published revision of the client: a manifest of path => sha256, not an
      # archive. A zip's bytes depend on entry order, timestamps and
      # compression level, so the same source tree hashes differently on two
      # machines -- and a hash that depends on who built it proves nothing.
      #
      # `pubkey` is carried so a per-user trusted-developer setting can
      # arrive later without re-signing anything. Nothing consults it yet.
      def release(pubkey:, revision:, label:, files:, notes:, ack:, issued_at:, note: nil)
        {
          "purpose"   => RELEASE,
          "pubkey"    => pubkey,
          "revision"   => revision.to_i,
          "label"     => label,
          "files"     => files,
          "notes"     => notes,
          "ack"       => ack,
          "note"      => note,
          "ts"        => issued_at.to_i
        }
      end

      # An official statement from a publisher: an outage, a policy, a release.
      #
      # `kind` comes from a closed list the server publishes, for the same
      # reason an emote does -- an arbitrary string would be stored and then
      # rendered back to everyone, and a client cannot present something it has
      # never heard of.
      #
      # `supersedes` is the record hash of the notice this one replaces, or
      # nil. A correction is a new record pointing at the old one, never an
      # edit: a mutated record no longer matches its signature, and the point
      # of a notice is that what was said is still there to be checked.
      #
      # The founding notice is the one that supersedes nothing.
      def notice(pubkey:, revision:, kind:, title:, body:, ack:, issued_at:,
                 supersedes: nil, note: nil)
        {
          "purpose"    => NOTICE,
          "pubkey"     => pubkey,
          "revision"   => revision.to_i,
          "kind"       => kind,
          "title"      => title,
          "body"       => body,
          "supersedes" => supersedes,
          "ack"        => ack,
          "note"       => note,
          "ts"         => issued_at.to_i
        }
      end

      # There is no per-author sequence here. `ack` already names the records
      # this author had seen, their own included, so an author who wants their
      # own history provable acknowledges their own earlier records rather than
      # maintaining a second chain alongside the first one.
      #
      # `ts` is the client's clock and is attacker-controlled; the server
      # records its own receipt time separately and unsigned.
      #
      # `reply_to` is the record hash of the message being replied to, or nil.
      # Always present so the canonical form does not change shape between a
      # reply and an ordinary message.
      def message(pubkey:, room:, body:, ack:, issued_at:, reply_to: nil, note: nil)
        {
          "purpose"  => MESSAGE,
          "pubkey"   => pubkey,
          "room"     => room,
          "reply_to" => reply_to,
          "ack"      => ack,
          "note"     => note,
          "ts"       => issued_at.to_i,
          "body"     => body
        }
      end

      # One person's emote on one message. `message` is that message's
      # record hash. `room` is carried for the same reason a message carries
      # it: so an emote cannot be transplanted elsewhere.
      def emote(pubkey:, room:, message:, emote:, ack:, issued_at:, note: nil)
        {
          "purpose" => EMOTE,
          "pubkey"  => pubkey,
          "room"    => room,
          "message" => message,
          "emote"   => emote,
          "ack"     => ack,
          "note"    => note,
          "ts"      => issued_at.to_i
        }
      end

      # The owner's private document: settings, which comments have been emoted
      # on, and the friend and report lists. Encrypted, then signed.
      #
      # Encrypted under a key derived from the seed under `seed.kdf.vault_domain`
      # -- not under the identity key, because Ed25519 cannot encrypt and the
      # signing key is a non-extractable WebCrypto key whose bytes can never be
      # read back. See docs/project/identity.md.
      #
      # `revision` is OUTSIDE the ciphertext on purpose. The server has to be
      # able to reject a rollback, and that means reading one number from a
      # document it can otherwise make nothing of. It leaks roughly how many
      # times the owner has saved, and nothing else.
      #
      # No `ack` and no `note`: nobody else ever sees this, so there is nothing
      # to anchor it to and nobody to address.
      def vault(pubkey:, revision:, ciphertext:, iv:, issued_at:)
        {
          "purpose"    => VAULT,
          "pubkey"     => pubkey,
          "revision"   => revision.to_i,
          "ciphertext" => ciphertext,
          "iv"         => iv,
          "ts"         => issued_at.to_i
        }
      end
    end
  end
end
