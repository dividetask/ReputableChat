# frozen_string_literal: true

# Generates the genesis user record -- Tim's -- and writes it to
# config/genesis/tim.json for committing.
#
#   bundle exec rake genesis
#   bundle exec ruby script/generate_genesis.rb --handle Tim --words 12
#
# Writes two files: the genesis record, which is committed, and the seed, which
# is gitignored and 0600. Nothing secret is printed -- a terminal scrollback,
# a CI log and a screen share are all places a seed should not turn up.
#
# There is no recovery. Lose the seed file and the genesis identity is gone,
# and with it the ability to publish a release anyone will run, so back it up
# somewhere outside the checkout.
#
# Refuses to overwrite either file, because a second genesis would orphan every
# record in the chain that acknowledges the first.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "open3"
require "securerandom"
require "fileutils"
require "reputable_chat/config"
require "reputable_chat/params"
require "reputable_chat/cryptography/seed"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/record"
require "reputable_chat/cryptography/signature"
require "reputable_chat/genesis"
require "reputable_chat/operator"

module GenerateGenesis
  Crypto = ReputableChat::Cryptography
  HELPER = File.expand_path("derive_key.mjs", __dir__)

  module_function

  def run(argv)
    options = parse(argv)
    refuse_to_overwrite!(options[:path], "genesis record")
    refuse_to_overwrite!(options[:seed_path], "seed")

    kdf    = kdf_parameters
    phrase = new_phrase(options[:words])
    keys   = node("derive", phrase: phrase, kdf: kdf)

    payload   = record_for(keys["pubkey"], options)
    canonical = Crypto::Canonical.dump(payload)
    signature = node("sign", private_key: keys["private_key"], message: canonical)["signature"]

    # Verified with the Ruby verifier the server actually uses, so a mismatch
    # between the two halves of the crypto shows up here rather than as every
    # login failing later for no visible reason.
    verify!(keys["pubkey"], signature, payload)

    hash = Crypto::Record.digest(payload: canonical, signature: signature)
    write(options[:path], pubkey: keys["pubkey"], payload: canonical, signature: signature, hash: hash)
    ReputableChat::Operator.write_seed(phrase, path: options[:seed_path])

    report(options, keys["pubkey"], hash)
  end

  # --- steps ------------------------------------------------------------

  def kdf_parameters
    config = ReputableChat::Config.load
    {
      "domain"      => config.fetch("seed.kdf.domain"),
      "iterations"  => config.integer("seed.kdf.iterations"),
      "memory_kib"  => config.integer("seed.kdf.memory_kib"),
      "parallelism" => config.integer("seed.kdf.parallelism")
    }
  end

  # Built through the reference implementation so the phrase is one the browser
  # will accept unchanged -- including the checksum, which is what stops a
  # mistyped word from silently becoming a different account.
  def new_phrase(words)
    bits   = SecureRandom.bytes((Crypto::Seed.entropy_bits_for(words) / 8.0).ceil)
                         .unpack1("B*")[0, Crypto::Seed.entropy_bits_for(words)]
    phrase = Crypto::Seed.encode(bits, words)

    Crypto::Seed.validate!(phrase, min_words: words)
    Crypto::Seed.normalize(phrase)
  end

  # `ack` is null: this is the one record in the system that acknowledges
  # nothing, because there was nothing to acknowledge.
  def record_for(pubkey, options)
    Crypto::Payload.user(
      pubkey: pubkey, version: 1, handle: options[:handle], bio: options[:bio],
      icon: nil, ack: nil, issued_at: Time.now.to_i
    )
  end

  def verify!(pubkey, signature, payload)
    return if Crypto::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)

    abort "the signature did not verify against the Ruby verifier -- refusing to write a genesis nobody can check"
  end

  def write(path, record)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(record.transform_keys(&:to_s))}\n")
  end

  def node(command, payload)
    out, err, status = Open3.capture3("node", HELPER, command, stdin_data: JSON.generate(payload))
    abort "node #{command} failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  # --- reporting --------------------------------------------------------

  # Public key and record hash only. Both are public by definition -- the
  # record hash is what every other record will acknowledge, and the public key
  # is the identity itself. The seed is never printed.
  def report(options, pubkey, hash)
    puts
    puts "  Genesis created."
    puts
    puts "  Record       #{relative(options[:path])}"
    puts "  Seed         #{relative(options[:seed_path])}  (0600, gitignored, never printed)"
    puts "  Public key   #{pubkey}"
    puts "  Record hash  #{hash}"
    puts
    puts "  Commit the record: every client needs the same genesis hash before"
    puts "  it has fetched anything, so it cannot be downloaded."
    puts
    puts "  Back the seed up somewhere outside this checkout. It is the whole"
    puts "  identity and there is no recovery."
    puts
  end

  def relative(path) = path.sub("#{File.expand_path('..', __dir__)}/", "")

  # --- options ----------------------------------------------------------

  DEFAULT_BIO = "Tim is legally distinct from, and no relation to, Tom"

  DEFAULTS = { handle: "Tim", bio: DEFAULT_BIO, words: 12,
               path: ReputableChat::Genesis::PATH,
               seed_path: ReputableChat::Operator::SEED_PATH }.freeze

  def parse(argv)
    options = DEFAULTS.dup

    until argv.empty?
      flag = argv.shift
      case flag
      when "--handle" then options[:handle] = argv.shift.to_s
      when "--bio"    then options[:bio]    = argv.shift.to_s
      when "--words"  then options[:words]  = Integer(argv.shift)
      when "--path"   then options[:path]   = File.expand_path(argv.shift.to_s)
      when "--seed"   then options[:seed_path] = File.expand_path(argv.shift.to_s)
      when "--help", "-h" then usage
      else abort "unknown option: #{flag}\n\n#{usage_text}"
      end
    end

    validate_options!(options)
    options
  end

  # Checked through the same helpers every other profile goes through. The
  # genesis is written once and can never be reissued without orphaning the
  # chain, so a handle or bio the rest of the system would reject has to be
  # caught here rather than discovered later.
  def validate_options!(options)
    minimum = ReputableChat::Config.load.integer("seed.min_words")
    abort "a seed needs at least #{minimum} words" if options[:words] < minimum

    unless ReputableChat::Params.string(options[:handle], max: ReputableChat::Params::MAX_USERNAME)
      abort "a handle is required, at most #{ReputableChat::Params::MAX_USERNAME} bytes and no control characters"
    end

    return if options[:bio].empty?
    return if ReputableChat::Params.string(options[:bio], max: ReputableChat::Params::MAX_BIO)

    abort "a bio is at most #{ReputableChat::Params::MAX_BIO} bytes and has no control characters"
  end

  # Overwriting would orphan every record that acknowledges the old genesis,
  # which is to say the entire chain.
  def refuse_to_overwrite!(path, what)
    return unless File.exist?(path)

    abort "the #{what} at #{relative(path)} already exists. Delete it deliberately if you " \
          "really mean to start a new chain -- every record acknowledging the old genesis " \
          "becomes unanchored."
  end

  def usage
    puts usage_text
    exit 0
  end

  def usage_text
    <<~TEXT
      usage: bundle exec ruby script/generate_genesis.rb [options]

        --handle NAME   display handle for the genesis account (default: Tim)
        --bio TEXT      bio for the genesis account
                        (default: "#{DEFAULT_BIO}")
        --words N       seed length; more than the 8-word minimum, since this
                        key signs releases (default: 12)
        --path FILE     where to write the record (default: config/genesis/tim.json)
        --seed FILE     where to write the seed (default: config/genesis/seed)
    TEXT
  end
end

GenerateGenesis.run(ARGV) if $PROGRAM_NAME == __FILE__
