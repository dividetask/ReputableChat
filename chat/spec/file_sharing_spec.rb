# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_server"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "tmpdir"
require "reputable_chat/store/images"

# Two real chat servers sharing files, each beside its own agnostic server.
#
# FilePeersSpec fakes the network; this runs it. Each chat server boots as it
# would in production -- config.ru, its own database, image root and host
# account -- announces itself, and the two agnostic servers are given each
# other's records the way syncing would give them, so each chat learns of the
# other from the chain alone.
#
# In order, because a failed fetch puts the other server off for a while, as
# it should: the one test that makes a fetch fail runs last.
class FileSharingSpec < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  ROOT = File.expand_path("..", __dir__)

  # A chat server and the agnostic server beside it.
  Side = Struct.new(:chain, :dir, :url, :images, :account, :pid)

  def self.sides = @sides ||= start
  def sides = self.class.sides
  def here = sides.fetch(:here)
  def there = sides.fetch(:there)

  def self.start
    here = side("here")
    there = side("there")
    # Each chat announced itself to its own agnostic server; syncing would
    # carry each announcement to the other.
    copy_records(from: there.chain, to: here.chain)
    copy_records(from: here.chain, to: there.chain)
    { here: here, there: there }
  end

  def self.side(name)
    dir = Dir.mktmpdir("chat-spec-#{name}")
    chain = ChainServer.launch(dir)
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    url = "http://127.0.0.1:#{port}"
    log = File.join(dir, "chat.log")
    pid = ChainServer.clean_env do
      Process.spawn(
        { "RACK_ENV" => "development", "SESSION_SECRET" => SecureRandom.hex(64), "ORIGIN" => nil,
          "DATABASE_URL" => "sqlite://#{dir}/chat.db", "IMAGE_ROOT" => "#{dir}/images",
          "CHAIN_URL" => chain, "HOST_SEED" => File.join(dir, "development", "host.seed"),
          # Loopback is a private address; development allows it, and this
          # says so rather than relying on the default.
          "PUBLIC_URL" => url, "ALLOW_PRIVATE_PEERS" => "1",
          "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") },
        "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{port}", "-q",
        chdir: ROOT, out: log, err: log
      )
    end
    at_exit do
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    wait_for(url, log)
    account = JSON.parse(Net::HTTP.get(URI("#{chain}/api/host"))).fetch("id")
    Side.new(chain, dir, url, ReputableChat::Store::Images.new(File.join(dir, "images")), account, pid)
  end

  def self.wait_for(url, log)
    120.times do
      return if Net::HTTP.get_response(URI("#{url}/api/limits")).is_a?(Net::HTTPSuccess)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
      sleep 0.5
    end
    raise "the chat server at #{url} did not start; its log:\n#{File.read(log)}"
  end

  def self.copy_records(from:, to:)
    page = JSON.parse(Net::HTTP.get(URI("#{from}/api/records?since=0&limit=500")))
    uri = URI("#{to}/api/records")
    response = Net::HTTP.post(uri, JSON.generate("records" => page.fetch("records")),
                              "Content-Type" => "application/json")
    raise "#{to} refused the records from #{from}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
  end

  def image(fill)
    bytes = "\x89PNG\r\n\x1A\n".b + (fill * 64).b
    [bytes, "#{Digest::SHA256.hexdigest(bytes)}.png"]
  end

  def get(url, peer: false)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    request[ReputableChat::FilePeers::PEER_HEADER] = "1" if peer
    Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(request) }
  end

  # RULE (yours): a chat server announces itself with a service notice from
  # its host account, and another learns of it from the chain alone.
  def test_1_each_chat_server_knows_the_other_from_the_chain
    page = JSON.parse(Net::HTTP.get(URI("#{here.chain}/api/records?since=0&limit=500")))
    notices = page.fetch("records").map { |r| JSON.parse(r["payload"]) }
                  .select { |p| p["kind"] == "service" && p["id"] == there.account }

    assert_equal [there.url], notices.map { |p| p["url"] }
  end

  # RULE: a file this chat server lacks is fetched from the one that has it,
  # checked against its name, and kept.
  def test_2_a_file_one_server_lacks_is_fetched_from_the_other
    bytes, name = image("a")
    there.images.store(bytes)

    response = get("#{here.url}/images/#{name}")

    assert_equal "200", response.code
    assert_equal bytes, response.body.b
    assert_equal bytes, here.images.read(name), "kept, so the next request is answered from here"
  end

  # RULE: a request from another chat server is answered from what is here
  # and never passed on, so two servers cannot ask each other in circles.
  def test_3_a_request_from_another_chat_server_is_not_passed_on
    bytes, name = image("b")
    here.images.store(bytes)

    assert_equal "404", get("#{there.url}/images/#{name}", peer: true).code
    assert_nil there.images.read(name)

    assert_equal "200", get("#{there.url}/images/#{name}").code, "a browser's request is passed on"
  end

  # RULE: bytes that do not hash to the name are refused, so no server can
  # put another file in a record's place.
  def test_4_a_substituted_file_is_refused
    _, name = image("c")
    File.binwrite(File.join(there.dir, "images", name), image("d").first)

    assert_equal "404", get("#{here.url}/images/#{name}").code
    assert_nil here.images.read(name)
  end
end
