# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require_relative "config"
require_relative "cryptography/seed"
require_relative "cryptography/canonical"
require_relative "cryptography/signature"

module ReputableChat
  # Signing as the genesis account from a terminal.
  #
  # Everything else in this project keeps private keys inside the browser, in a
  # non-extractable WebCrypto key. This is the one deliberate exception: the
  # genesis account has to post announcements and vouch for new arrivals
  # without a person sitting at a browser, so its seed lives in a file.
  #
  # That file is a real secret and the weakest point in the system -- whoever
  # holds it is the genesis account. It is gitignored, written 0600, and
  # deliberately holds the SEED PHRASE rather than the derived private key, so
  # that it is the same thing a person would type into the UI and there is only
  # one secret to look after rather than two.
  module Operator
    SEED_PATH = File.expand_path("../../config/genesis/seed", __dir__)
    HELPER    = File.expand_path("../../script/derive_key.mjs", __dir__)

    class MissingSeed < StandardError; end
    class HelperFailed < StandardError; end

    module_function

    def seed_path = ENV.fetch("GENESIS_SEED", SEED_PATH)

    # Read, normalized and checked. A seed file that has picked up a stray edit
    # would otherwise derive a different key in silence and sign as an account
    # nobody has ever heard of.
    def seed_phrase(path: seed_path)
      raise MissingSeed, missing_message(path) unless File.exist?(path)

      phrase = Cryptography::Seed.normalize(File.read(path))
      Cryptography::Seed.validate!(phrase, min_words: Config.load.integer("seed.min_words"))

      phrase
    end

    def missing_message(path)
      "no seed at #{path}. `bundle exec rake genesis` writes one; it is gitignored " \
        "and never committed, so a fresh clone does not have it."
    end

    # Written 0600 before anything is put in it, so the secret is never briefly
    # readable by everyone on the machine.
    def write_seed(phrase, path: seed_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.puts(phrase) }
      File.chmod(0o600, path)
      path
    end

    def seed_readable_by_others?(path: seed_path)
      File.exist?(path) && (File.stat(path).mode & 0o077) != 0
    end

    # --- deriving and signing ----------------------------------------------

    # The KDF parameters come from config/reputation.yml, the same ones the
    # browser reads, so a terminal and a browser holding the same phrase reach
    # the same key.
    def kdf(config = Config.load)
      {
        "domain"      => config.fetch("seed.kdf.domain"),
        "iterations"  => config.integer("seed.kdf.iterations"),
        "memory_kib"  => config.integer("seed.kdf.memory_kib"),
        "parallelism" => config.integer("seed.kdf.parallelism")
      }
    end

    def derive(phrase, kdf_parameters = kdf)
      node("derive", phrase: phrase, kdf: kdf_parameters)
    end

    def sign(private_key, payload)
      canonical = payload.is_a?(String) ? payload : Cryptography::Canonical.dump(payload)
      node("sign", private_key: private_key, message: canonical)["signature"]
    end

    # Argon2id and Ed25519 both live in Node here, because that is what the
    # browser runs. A second Ruby implementation of either could drift from it
    # and strand the account.
    def node(command, payload)
      out, err, status = Open3.capture3("node", HELPER, command, stdin_data: JSON.generate(payload))
      raise HelperFailed, "node #{command} failed: #{err}" unless status.success?

      JSON.parse(out)
    end
  end
end
