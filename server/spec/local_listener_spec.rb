# frozen_string_literal: true

require_relative "spec_helper"
require "servers"
require "socket"

# The apps beside a server reach it on a Unix socket only they can open. On
# it uploads need no signature and adjustments are taken; on the public
# listener neither. Which listener a request came in on is read from the
# connection, never from the request.
class LocalListenerSpec < Minitest::Test
  include Servers

  def setup
    @alpha = boot("alpha")
    @beta = boot("beta")
    @alpha.ingest.submit(@beta.host.declaration)
    @path = @alpha.settings.local_socket
    @sockets = []
  end

  def teardown
    @sockets.each { |s| s.close unless s.closed? }
    @listener&.stop
    super
  end

  # A connection accepted on a Unix socket at path, as Puma hands it over.
  def accepted_on(path)
    FileUtils.mkdir_p(File.dirname(path))
    server = UNIXServer.new(path)
    client = UNIXSocket.new(path)
    accepted = server.accept
    @sockets.push(server, client, accepted)
    File.unlink(path)
    accepted
  end

  def post(path, body, socket: nil, **env)
    env = env.merge("CONTENT_TYPE" => "application/json", input: JSON.generate(body))
    env["puma.socket"] = socket if socket
    Rack::MockRequest.new(@alpha.app).post(path, env)
  end

  def note = @beta.host.sign("message", { "ack" => [@beta.host.id], "body" => "hello", "ts" => Time.now.to_i })

  def adjustment(**fields) = { "app" => "chat", "account" => @beta.host.id, "reputation" => "0.004", "trust" => "0" }
                             .merge(fields.transform_keys(&:to_s))

  def test_the_socket_is_in_the_host_directory
    assert_equal File.join(@alpha.settings.host_dir, "server.sock"), @path
  end

  def test_an_upload_on_the_local_listener_needs_no_signature
    response = post("/api/records", { "records" => [note.to_wire] }, socket: accepted_on(@path))
    assert_equal 200, response.status, response.body
    assert_equal "accepted", JSON.parse(response.body)["results"].first["status"]
  end

  # RULE (yours): records from an app are judged against the rules exactly as
  # anyone's are; the listener only spares the signature.
  def test_a_record_on_the_local_listener_is_still_checked
    forged = note.to_wire.merge("signature" => @alpha.host.sign("message", { "ack" => [@beta.host.id], "body" => "x", "ts" => 1 }).signature)
    response = post("/api/records", { "records" => [forged] }, socket: accepted_on(@path))
    refute_equal "accepted", JSON.parse(response.body)["results"].first["status"]
  end

  # Behind a reverse proxy on the same machine every outside request comes
  # from 127.0.0.1, so nothing a request says makes it local.
  def test_nothing_a_request_says_makes_it_local
    claims = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_X_FORWARDED_FOR" => "127.0.0.1", "HTTP_HOST" => "localhost",
               "SERVER_PORT" => "0", "agnostic.local" => true }
    assert_equal 401, post("/api/records", { "records" => [note.to_wire] }, **claims).status
    assert_equal 403, post("/api/adjustments", adjustment, **claims).status
  end

  # A public listener on a Unix socket of its own -- a reverse proxy's, say --
  # is not the local one.
  def test_another_unix_socket_is_not_the_local_listener
    other = accepted_on(File.join(File.dirname(@path), "public.sock"))
    assert_equal 401, post("/api/records", { "records" => [note.to_wire] }, socket: other).status
    assert_equal 403, post("/api/adjustments", adjustment, socket: other).status
  end

  def test_adjustments_are_taken_only_on_the_local_listener
    assert_equal 403, post("/api/adjustments", adjustment).status
    assert_equal 200, post("/api/adjustments", adjustment, socket: accepted_on(@path)).status
  end

  def test_an_adjustment_is_an_app_an_account_and_two_decimals_from_minus_one_to_one
    local = -> { accepted_on(@path) }
    [{ app: "Chat!" }, { account: "nobody" }, { account: @alpha.host.id }, { reputation: ".5" }, { reputation: "1.5" },
     { trust: "0.50" }, { trust: 0.5 }].each do |bad|
      assert_equal 400, post("/api/adjustments", adjustment(**bad), socket: local.call).status, bad.inspect
    end
  end

  # RULE (yours): one adjustment per app and account, replaced by the next;
  # "0" and "0" clears it.
  def test_a_new_adjustment_replaces_the_last_and_zero_clears_it
    post("/api/adjustments", adjustment, socket: accepted_on(@path))
    post("/api/adjustments", adjustment(reputation: "0.006"), socket: accepted_on(@path))
    assert_equal(["0.006"], @alpha.store.adjustments.map { |a| a[:reputation] })

    post("/api/adjustments", adjustment(reputation: "0", trust: "0"), socket: accepted_on(@path))
    assert_empty @alpha.store.adjustments
  end

  # The real thing: a socket only the server's user can open, answering HTTP.
  def test_the_listener_is_a_socket_only_the_servers_user_can_open
    @listener = Agnostic::LocalListener.new(@alpha.app, @path).start
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert File.socket?(@path)

    body = JSON.generate(adjustment)
    UNIXSocket.open(@path) do |s|
      s.write("POST /api/adjustments HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" \
              "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      assert_match %r{\AHTTP/1\.1 200}, s.read
    end
    assert_equal "0.004", @alpha.store.adjustments.first[:reputation]
  end

  def test_an_empty_socket_setting_turns_the_listener_off
    settings = Agnostic::Settings.new({ "local" => { "socket" => "" } }, env: {})
    assert_nil settings.local_socket
  end
end
