# frozen_string_literal: true

module ReputableChat
  module Cryptography
    # The signed payload shapes.
    #
    # Chain records follow docs/project/rules/v0.001.md, which says what each
    # field means; these builders only assemble them. A field with no value is
    # left out rather than written as null, so a record has one spelling. Lists
    # the rules require sorted are sorted here, because the chain refuses an
    # unsorted one rather than sorting it -- sorting would change what was
    # signed. Must stay in lockstep with the *Payload helpers in
    # public/js/identity.js.
    #
    # Two shapes are not records and the rules do not govern them: the login
    # challenge and the vault. Each names its purpose and the origin it was made
    # for, so a harvested signature cannot be replayed against another server.
    module Payload
      LOGIN = "reputablechat:login:v1"
      VAULT = "reputablechat:vault:v1"

      # The rules version every record this code makes conforms to.
      RULES_VERSION = "v0.001"
      # The further part of a record's type that says it belongs to the chat.
      CHAT = "chat"

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

      # The owner's private document: settings, the voted list, the friend and
      # report lists. Encrypted, then signed. Not a record on the chain.
      #
      # Encrypted under a key derived from the seed under `seed.kdf.vault_domain`
      # -- not under the identity key, because Ed25519 cannot encrypt and the
      # signing key is a non-extractable WebCrypto key whose bytes can never be
      # read back. See docs/project/identity.md.
      #
      # `revision` is OUTSIDE the ciphertext on purpose. The server has to be
      # able to reject a rollback, and that means reading one number from a
      # document it can otherwise make nothing of.
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

      # --- chain records ------------------------------------------------------

      def type(kind, app = nil) = ["reputablechat", kind, RULES_VERSION, app].compact.join(":")

      # Any record: the fields given, with the absent ones left out.
      def record(kind, app: nil, **fields)
        payload = fields.compact.transform_keys(&:to_s)
        %w[ack target endorse].each { |name| payload[name] = payload[name].uniq.sort if payload[name] }
        payload["ts"] = payload["ts"].to_i if payload.key?("ts")
        payload.merge("type" => type(kind, app))
      end

      # An identity declaration. The first has no id, and its record hash
      # becomes the account ID; the genesis is a first declaration that also
      # carries the rules and acknowledges nothing.
      def identity(pubkey:, handle:, ack:, ts:, bio: "", avatar: nil, id: nil, mpubkey: nil,
                   rules: nil, adjudicators: nil, transfer: nil)
        record("identity", id: id, pubkey: pubkey, mpubkey: mpubkey, title: handle, body: bio,
                           file: avatar && [avatar], ack: ack, ts: ts, rules: rules,
                           adjudicators: adjudicators, transfer: transfer)
      end

      # What somebody thinks of everyone else: account ID to
      # {"reputation" => "0.5", "trust" => "1"}, both decimal strings.
      def attestation(id:, pubkey:, scores:, ack:, ts:, derived: nil, body: "")
        record("attestation", id: id, pubkey: pubkey, scores: scores, derived: derived, body: body,
                              ack: ack, ts: ts)
      end

      # `extra` takes the optional fields a message may carry and the chat does
      # not use, such as endorse or transfer.
      def message(id:, pubkey:, body:, ack:, ts:, target: nil, app: CHAT, **extra)
        record("message", app: app, id: id, pubkey: pubkey, body: body, ack: ack, ts: ts,
                          target: target, **extra)
      end

      def reaction(id:, pubkey:, body:, target:, ack:, ts:, app: CHAT)
        record("reaction", app: app, id: id, pubkey: pubkey, body: body, target: target,
                           ack: ack, ts: ts)
      end

      def notice(id:, pubkey:, kind:, body:, ack:, ts:, title: nil, target: nil, endorse: nil)
        record("notice", id: id, pubkey: pubkey, kind: kind, title: title, body: body,
                         target: target, endorse: endorse, ack: ack, ts: ts)
      end

      def heartbeat(id:, pubkey:, ack:, ts:, endorse: nil)
        record("heartbeat", id: id, pubkey: pubkey, body: "", ack: ack, ts: ts, endorse: endorse)
      end

      def release(id:, pubkey:, version:, rules:, ack:, ts:, body: "")
        record("release", id: id, pubkey: pubkey, rules: rules, body: body, ack: ack, ts: ts)
          .merge("type" => "reputablechat:release:#{version}")
      end
    end
  end
end
