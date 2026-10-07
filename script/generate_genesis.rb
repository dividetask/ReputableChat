# frozen_string_literal: true

# Generates a committed identity declaration: the genesis account's, which is
# the bottom of the chain, or with --host the host account's, which is this
# server's own and acknowledges the genesis.
#
#   bundle exec rake genesis                      # development genesis
#   RACK_ENV=production bundle exec rake genesis   # production genesis
#   bundle exec rake host                         # development host account
#   bundle exec ruby script/generate_genesis.rb --host --production \
#     --handle Ops --bio "Announcements for this server" --icon ops.png
#
# Writes two files, the record and the seed beside it, plus the icon when one
# is given. The genesis goes under config/genesis/, the host account under
# config/host/.
#
# Which pair depends on the environment. The DEVELOPMENT seed is committed and
# therefore public -- anyone who has cloned the repository owns that identity,
# which is the point: a fresh clone can run the genesis account locally without
# being handed a secret. The PRODUCTION seed is gitignored, 0600, and never
# printed, because a terminal scrollback, a CI log and a screen share are all
# places it should not turn up.
#
# There is no recovery for the production one. Lose it and the genesis identity
# is gone, and with it the ability to publish a release anyone will run, so
# back it up somewhere outside the checkout.
#
# Refuses to overwrite either file, because a second genesis would orphan every
# record in the chain that acknowledges the first, and a second host account
# would orphan the vouches its server's people received from the first.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "open3"
require "securerandom"
require "fileutils"
require "tmpdir"
require "digest"
require "reputable_chat/config"
require "reputable_chat/params"
require "reputable_chat/cryptography/seed"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/record"
require "reputable_chat/cryptography/signature"
require "reputable_chat/environment"
require "reputable_chat/genesis"
require "reputable_chat/host"
require "reputable_chat/store/images"
require "reputable_chat/operator"

module GenerateGenesis
  Crypto = ReputableChat::Cryptography
  HELPER = File.expand_path("derive_key.mjs", __dir__)

  module_function

  def run(argv)
    options = parse(argv)
    refuse_to_overwrite!(options[:path], options[:account] == :host ? "host account" : "genesis record")
    refuse_to_overwrite!(options[:seed_path], "seed")

    if options[:icon_source]
      options[:icon] = install_icon(options[:icon_source], options[:path].sub(/\.json\z/, ""))
    end

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

  # The genesis acknowledges nothing, because there was nothing to
  # acknowledge. A host account acknowledges the genesis it serves.
  def record_for(pubkey, options)
    Crypto::Payload.identity(
      pubkey: pubkey, revision: 1, handle: options[:handle], bio: options[:bio],
      icon: options[:icon], ack: options[:ack], issued_at: Time.now.to_i
    )
  end

  # Copies the image in beside the record and returns the content-addressed
  # name to sign. The name is the hash of the bytes, so committing them is what
  # lets any reader confirm the avatar is the one that was signed for.
  def install_icon(source, destination_stem)
    raw = File.binread(source)
    abort "  #{relative(source)} is #{raw.bytesize} bytes; the limit is #{ReputableChat::Store::Images::MAX_BYTES}" if
      raw.bytesize > ReputableChat::Store::Images::MAX_BYTES

    extension = ReputableChat::Store::Images.new(Dir.mktmpdir).sniff(raw)
    abort "  #{relative(source)} is not a PNG, JPEG, GIF or WebP" unless extension

    File.binwrite("#{destination_stem}.#{extension}", raw)
    "#{Digest::SHA256.hexdigest(raw)}.#{extension}"
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
    production = options[:environment] == ReputableChat::Environment::PRODUCTION
    what = options[:account] == :host ? "Host account" : "Genesis"

    puts
    puts "  #{what} created for #{options[:environment]}."
    puts
    puts "  Record       #{relative(options[:path])}"
    puts "  Seed         #{relative(options[:seed_path])}#{production ? '  (0600, gitignored, never printed)' : '  (0600, committed on purpose -- this identity is public)'}"
    puts "  Public key   #{pubkey}"
    puts "  Record hash  #{hash}"
    puts "  Acknowledges #{options[:ack]} (the genesis)" if options[:ack]
    puts

    if production
      puts "  Commit the record, never the seed. Back the seed up somewhere"
      puts "  outside this checkout: it is the whole identity and there is no"
      puts "  recovery."
    else
      puts "  Commit both. The development identity is meant to be shared, so"
      puts "  that a fresh clone can sign as this account without being"
      puts "  handed a secret. Never point a production deployment at it --"
      puts "  the server refuses to boot if you do."
    end
    puts
  end

  def relative(path) = path.sub("#{File.expand_path('..', __dir__)}/", "")

  # --- options ----------------------------------------------------------

  DEFAULT_BIO = "Tim is legally distinct from, and no relation to, Tom"
  DEFAULT_HOST_HANDLE = "Host"
  DEFAULT_HOST_BIO    = "This server's own account"

  DEFAULTS = { account: :genesis, handle: nil, bio: nil, words: 12,
               environment: nil, path: nil, seed_path: nil,
               icon_source: nil, icon: nil, ack: nil }.freeze

  def parse(argv)
    options = DEFAULTS.dup
    environment = nil

    until argv.empty?
      flag = argv.shift
      case flag
      when "--handle" then options[:handle] = argv.shift.to_s
      when "--bio"    then options[:bio]    = argv.shift.to_s
      when "--icon"   then options[:icon_source] = File.expand_path(argv.shift.to_s)
      when "--words"  then options[:words]  = Integer(argv.shift)
      when "--path"   then options[:path]   = File.expand_path(argv.shift.to_s)
      when "--seed"   then options[:seed_path] = File.expand_path(argv.shift.to_s)
      when "--host"   then options[:account] = :host
      when "--production"  then environment = ReputableChat::Environment::PRODUCTION
      when "--development" then environment = ReputableChat::Environment::DEVELOPMENT
      when "--help", "-h" then usage
      else abort "unknown option: #{flag}\n\n#{usage_text}"
      end
    end

    # An explicit flag wins over RACK_ENV, so a production genesis can be cut
    # from a development shell without exporting anything.
    options[:environment] = environment || ReputableChat::Environment.name
    host = options[:account] == :host
    record_class = host ? ReputableChat::Host : ReputableChat::Genesis

    options[:handle] ||= host ? DEFAULT_HOST_HANDLE : "Tim"
    options[:bio]    ||= host ? DEFAULT_HOST_BIO : DEFAULT_BIO
    options[:path] ||= record_class.path(options[:environment])
    options[:seed_path] ||= ReputableChat::Operator.path_for(options[:environment], account: options[:account])
    options[:ack] = genesis_hash(options[:environment]) if host

    validate_options!(options)
    options
  end

  # The genesis of the same environment, loaded and verified. A host account
  # signed against a genesis the server does not run would be refused at boot,
  # so it is refused here instead, before a seed is spent on it.
  def genesis_hash(environment)
    ReputableChat::Genesis.load(path: ReputableChat::Genesis.path(environment)).hash
  rescue ReputableChat::Genesis::Missing, ReputableChat::Genesis::Corrupt => e
    abort "  a host account acknowledges the genesis, and there is no usable one: #{e.message}"
  end

  # Checked through the same helpers every other profile goes through. The
  # genesis is written once and can never be reissued without orphaning the
  # chain, so a handle or bio the rest of the system would reject has to be
  # caught here rather than discovered later.
  def validate_options!(options)
    minimum = ReputableChat::Config.load.integer("seed.min_words")
    abort "a seed needs at least #{minimum} words" if options[:words] < minimum

    unless ReputableChat::Params.handle(options[:handle])
      abort "a handle is required, at most #{ReputableChat::Params::MAX_HANDLE} bytes and no control characters"
    end

    return if ReputableChat::Params.bio(options[:bio])

    abort "a bio is at most #{ReputableChat::Params::MAX_BIO} bytes and has no control characters"
  end

  # Overwriting would orphan every record that acknowledges the old genesis,
  # which is to say the entire chain.
  def refuse_to_overwrite!(path, what)
    return unless File.exist?(path)

    abort "the #{what} at #{relative(path)} already exists. Delete it deliberately if you " \
          "really mean to replace it -- every record acknowledging the old one " \
          "becomes unanchored."
  end

  def usage
    puts usage_text
    exit 0
  end

  def usage_text
    <<~TEXT
      usage: bundle exec ruby script/generate_genesis.rb [options]

        --host          generate this server's host account, which
                        acknowledges the genesis, instead of the genesis
        --handle NAME   display handle (default: Tim, or #{DEFAULT_HOST_HANDLE} with --host)
        --bio TEXT      bio (default: "#{DEFAULT_BIO}",
                        or "#{DEFAULT_HOST_BIO}" with --host)
        --words N       seed length; more than the 8-word minimum, since this
                        key signs releases (default: 12)
        --icon FILE     avatar (PNG, JPEG, GIF or WebP). Copied in beside the
                        record and committed, because the image store is not
                        in the repository and the record is read before any
                        client has fetched anything.
        --production    cut the production account; its seed is never
                        committed and never printed
        --development   cut the development account (the default); its seed
                        is committed on purpose so a clone can use it
        --path FILE     where to write the record
        --seed FILE     where to write the seed
    TEXT
  end
end

GenerateGenesis.run(ARGV) if $PROGRAM_NAME == __FILE__
