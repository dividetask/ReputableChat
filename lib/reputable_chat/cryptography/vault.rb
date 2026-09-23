# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module ReputableChat
  module Cryptography
    # The private vault, from Ruby. `public/js/vault.js` is the same thing in the
    # browser, and the two must agree byte for byte or the genesis account's
    # terminal and a browser holding the same phrase see different vaults.
    #
    # There is no second derivation here: the key comes from the raw Argon2id
    # output that `Operator.derive` already returns as `private_key`, run through
    # HKDF under `seed.kdf.vault_domain`. Ruby only has to do HKDF and AES-GCM,
    # both of which are in OpenSSL -- Argon2id and Ed25519 stay in Node, because
    # those are the parts a second implementation could drift on and strand an
    # account. `spec/vault_parity_spec.rb` holds the two halves together.
    module Vault
      IV_BYTES  = 12
      TAG_BYTES = 16
      KEY_BYTES = 32

      class Unopenable < StandardError; end

      module_function

      def b64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

      def from_b64url(text)
        Base64.urlsafe_decode64(text + "=" * ((4 - (text.length % 4)) % 4))
      end

      # The domain separation is the HKDF `info`, so an empty salt is correct
      # rather than lazy: the input is already the output of a memory-hard KDF
      # over its own domain. WebCrypto's deriveKey does exactly this.
      def derive_key(raw_seed, domain)
        OpenSSL::KDF.hkdf(raw_seed, salt: "", info: domain, length: KEY_BYTES, hash: "SHA256")
      end

      # A fresh nonce every time. Reusing one under AES-GCM leaks the XOR of the
      # two plaintexts and breaks the authentication outright, and a vault is
      # written on every change.
      #
      # WebCrypto returns the tag appended to the ciphertext, so this appends it
      # too; splitting them would produce something the browser cannot open.
      def seal(key, value)
        iv = OpenSSL::Random.random_bytes(IV_BYTES)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = key
        cipher.iv  = iv

        sealed = cipher.update(JSON.generate(value)) + cipher.final

        { "ciphertext" => b64url(sealed + cipher.auth_tag(TAG_BYTES)), "iv" => b64url(iv) }
      end

      # Returns nil rather than raising on anything that does not open, matching
      # the browser: a vault that will not decrypt is one from a different seed
      # or a corrupted one, and neither is worth losing the session over.
      def unseal(key, ciphertext:, iv:)
        blob = from_b64url(ciphertext)
        return nil if blob.bytesize <= TAG_BYTES

        decipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        decipher.key = key
        decipher.iv  = from_b64url(iv)
        decipher.auth_tag = blob[-TAG_BYTES..]

        JSON.parse(decipher.update(blob[0...-TAG_BYTES]) + decipher.final)
      rescue OpenSSL::Cipher::CipherError, ArgumentError, JSON::ParserError
        nil
      end
    end
  end
end
