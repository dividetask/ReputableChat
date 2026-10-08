# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/test"
require "ed25519"
require "reputable_chat/app"
require "reputable_chat/cryptography/signature"
require "reputable_chat/cryptography/payload"
require "tmpdir"
require "digest"

class AppSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Payload = ReputableChat::Cryptography::Payload
  Canon   = ReputableChat::Cryptography::Canonical

  ORIGIN = "http://example.test"

  def setup
    ReputableChat::App.store  = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origins = [ORIGIN]
    ReputableChat::App.genesis = GenesisFixture.build
    ReputableChat::App.host = nil
    ReputableChat::App.book = ReputableChat::Chain::Book.new(ReputableChat::App.store,
                                                             genesis: ReputableChat::App.genesis.record)
    @signing = Ed25519::SigningKey.generate
    @pubkey  = Sig.encode(@signing.verify_key.to_bytes)
  end

  def app = ReputableChat::App.app

  def sign(payload) = Sig.encode(@signing.sign(Canon.bytes(payload)))

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def json = JSON.parse(last_response.body)

  def challenge
    post_json "/api/challenge", {}
    json["nonce"]
  end

  def log_in
    nonce = challenge
    ts = Time.now.to_i
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    post_json "/api/session",
              { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }
  end

  # --- login ------------------------------------------------------------

  def test_login_round_trip
    log_in

    assert_equal 200, last_response.status
    assert_equal @pubkey, json["pubkey"]
    refute json["registered"], "a fresh key should not be registered yet"
  end

  def test_rejects_a_bad_signature
    nonce = challenge
    ts = Time.now.to_i
    other = Ed25519::SigningKey.generate
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    forged = Sig.encode(other.sign(Canon.bytes(payload)))

    post_json "/api/session", { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => forged }

    assert_equal 401, last_response.status
  end

  # RULE: with origins configured, a signature made for another origin must
  # not authenticate here. That is what stops a malicious server relaying a
  # live login to this one.
  def test_rejects_a_signature_bound_to_another_origin
    nonce = challenge
    ts = Time.now.to_i
    elsewhere = Payload.login(pubkey: @pubkey, nonce: nonce, origin: "http://evil.test", issued_at: ts)

    post_json "/api/session",
              { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(elsewhere) }

    assert_equal 401, last_response.status
  end

  # RULE: an operator can list more than one origin, and a login signed for
  # any of them is accepted.
  def test_accepts_any_configured_origin
    ReputableChat::App.origins = [ORIGIN, "https://chat.example.test"]

    assert_equal 200, log_in_as("https://chat.example.test").status
  end

  # RULE: a mismatch says which origin the server expected and which the page
  # is at, rather than only that the signature failed.
  def test_a_wrong_origin_names_both_origins
    log_in_as("http://192.168.1.10:9292", headers: { "HTTP_ORIGIN" => "http://192.168.1.10:9292" })

    assert_equal 401, last_response.status
    assert_includes json["error"], ORIGIN
    assert_includes json["error"], "http://192.168.1.10:9292"
  end

  # --- login with no origin configured ----------------------------------

  # RULE: a server with no origin configured accepts a login signed for the
  # address it was reached at, so it runs at any domain or IP unconfigured.
  def test_unconfigured_server_takes_its_origin_from_the_request
    ReputableChat::App.origins = []

    assert_equal 200, log_in_as("http://192.168.1.10:9292", headers: { "HTTP_HOST" => "192.168.1.10:9292" }).status
  end

  def test_unconfigured_server_still_rejects_another_origin
    ReputableChat::App.origins = []

    log_in_as("http://elsewhere.test", headers: { "HTTP_HOST" => "chat.example.test" })

    assert_equal 401, last_response.status
  end

  # RULE: behind a reverse proxy the app sees the proxy's connection, so the
  # origin is rebuilt from X-Forwarded-Proto and X-Forwarded-Host, taking the
  # first of a list -- the one the outermost proxy, facing the browser, saw.
  def test_unconfigured_server_believes_the_reverse_proxy
    ReputableChat::App.origins = []
    behind_nginx = { "HTTP_HOST" => "127.0.0.1:9292", "HTTP_X_FORWARDED_PROTO" => "https, http",
                     "HTTP_X_FORWARDED_HOST" => "chat.example.test" }

    assert_equal 200, log_in_as("https://chat.example.test", headers: behind_nginx).status
  end

  def test_unconfigured_server_with_a_proxy_passing_only_host_and_scheme
    ReputableChat::App.origins = []
    behind_nginx = { "HTTP_HOST" => "chat.example.test", "HTTP_X_FORWARDED_PROTO" => "https" }

    assert_equal 200, log_in_as("https://chat.example.test", headers: behind_nginx).status
  end

  def log_in_as(origin, headers: {})
    nonce = challenge
    ts = Time.now.to_i
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: origin, issued_at: ts)
    post "/api/session",
         JSON.generate({ "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }),
         { "CONTENT_TYPE" => "application/json" }.merge(headers)
    last_response
  end

  def test_a_challenge_cannot_be_replayed
    nonce = challenge
    ts = Time.now.to_i
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    body = { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }

    post_json "/api/session", body
    assert_equal 200, last_response.status

    post_json "/api/session", body
    assert_equal 401, last_response.status, "a spent challenge must not work twice"
  end

  def test_rejects_a_stale_timestamp
    nonce = challenge
    ts = Time.now.to_i - 3_600
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)

    post_json "/api/session", { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  def test_writes_require_a_session
    post_json "/api/record", { "payload" => "{}", "signature" => "x" }

    assert_equal 401, last_response.status
  end

  # --- images ------------------------------------------------------------

  PNG = "\x89PNG\r\n\x1A\n".b + ("x" * 64).b

  def test_image_upload_is_content_addressed
    log_in
    post "/api/image", PNG, "CONTENT_TYPE" => "application/octet-stream"
    assert_equal 200, last_response.status

    icon = JSON.parse(last_response.body)["icon"]
    assert_equal "#{Digest::SHA256.hexdigest(PNG)}.png", icon,
                 "the filename must be the hash of the bytes"

    get "/images/#{icon}"
    assert_equal 200, last_response.status
    assert_equal "image/png", last_response.headers["Content-Type"]
    assert_equal PNG, last_response.body.b
  end

  # SVG is a script-bearing document. It must never be storable as an icon.
  def test_rejects_svg_and_other_unsniffable_uploads
    log_in

    post "/api/image", "<svg onload=alert(1)></svg>", "CONTENT_TYPE" => "image/svg+xml"
    assert_equal 400, last_response.status

    post "/api/image", "not an image at all", "CONTENT_TYPE" => "image/png"
    assert_equal 400, last_response.status, "a claimed content type must not be trusted"
  end

  def test_rejects_oversized_images
    log_in
    huge = "\x89PNG\r\n\x1A\n".b + ("x" * 300_000).b

    post "/api/image", huge, "CONTENT_TYPE" => "application/octet-stream"

    assert_equal 413, last_response.status
  end

  def test_image_names_cannot_traverse_paths
    log_in

    get "/images/..%2F..%2Fconfig%2Freputation.yml"
    refute_equal 200, last_response.status

    get "/images/#{'a' * 64}.svg"
    assert_equal 404, last_response.status
  end

  # RULE: the genesis is served so a client can check the hash it was built
  # with against the one this server runs, rather than meeting the mismatch as
  # signatures that will not verify.
  def test_serves_the_genesis_record
    get "/api/genesis"

    assert_equal 200, last_response.status
    assert_equal ReputableChat::App.genesis.hash, json["hash"]
    assert_equal json["hash"], json["account"], "a first declaration's hash is its account ID"
    assert_equal [], JSON.parse(json["payload"])["ack"]
  end

  def test_sets_a_strict_content_security_policy
    get "/api/identity/#{'a' * 64}"
    csp = last_response.headers["Content-Security-Policy"]

    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "frame-ancestors 'none'"
  end
end

# config.ru freezes the app class. Anything that lazily memoizes on first
# request raises FrozenError in production while passing every unfrozen test,
# so the frozen path gets its own coverage.
class FrozenAppSpec < Minitest::Test
  include Rack::Test::Methods

  # A subclass, so freezing does not leak into the rest of the suite. Note the
  # ordering this depends on, which config.ru also relies on: store and origin
  # must be assigned BEFORE the class is frozen, since they are class-level
  # accessors.
  FROZEN = Class.new(ReputableChat::App) do
    self.store  = ReputableChat::Store::Database.new("sqlite:/")
    self.images = ReputableChat::Store::Images.new(Dir.mktmpdir)
    self.origins = ["http://example.test"]
  end.freeze

  def app = FROZEN.app

  def test_serves_reputation_defaults_to_the_client
    get "/api/defaults"

    assert_equal 200, last_response.status
    config = JSON.parse(last_response.body)

    assert_equal "0.1", config.dig("constants", "k")
    assert_equal "0.0004", config.dig("vote_curve", "a")
    assert_equal 8, config.dig("seed", "min_words")
    assert_equal "argon2id", config.dig("seed", "kdf", "algorithm")
  end

  def test_serves_emote_polarity
    get "/api/emote-kinds"

    assert_equal 200, last_response.status
    emotes = JSON.parse(last_response.body)

    assert_operator emotes["positive"].size, :>, emotes["negative"].size,
                    "positive emotes should outnumber negative ones by design"
  end

  # RULE: /new-account is a real URL, so a refresh or a bookmark works.
  def test_new_account_is_its_own_url
    get "/new-account"

    assert_equal 200, last_response.status
    assert_includes last_response.headers["Content-Type"], "text/html"
    assert_includes last_response.body, "login-form"
  end

  def test_serves_the_wordlist
    get "/wordlist.txt"

    assert_equal 200, last_response.status
    assert_equal 2048, last_response.body.split("\n").size
  end

  # RULE: browsers must revalidate the app's own modules. Without an explicit
  # policy they cache each file independently on a heuristic, which after a
  # deploy leaves someone running a new app.js against a stale session.js --
  # and for signed payloads that is a silent failure, not a loud one.
  def test_modules_must_be_revalidated
    %w[/js/app.js /js/session.js /js/identity.js /css/app.css].each do |path|
      get path

      assert_equal 200, last_response.status, path
      assert_equal "no-cache", last_response.headers["Cache-Control"], path
    end
  end

  # RULE: things whose name is their content never need revalidating.
  def test_content_addressed_assets_stay_immutable
    get "/wordlist.txt"

    assert_includes last_response.headers["Cache-Control"], "immutable"
  end

  def test_security_headers_are_present_on_api_responses
    get "/api/defaults"

    assert_includes last_response.headers["Content-Security-Policy"], "default-src 'self'"
    assert_equal "DENY", last_response.headers["X-Frame-Options"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
  end
end
