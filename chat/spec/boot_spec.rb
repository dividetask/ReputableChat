# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_server"
require "net/http"
require "securerandom"
require "socket"
require "tmpdir"
require "reputable_chat/chain/connection"

# The chat waits for its agnostic server to be live before it does anything,
# its port included: until then nothing it was asked could be answered.
class BootSpec < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  Connection = ReputableChat::Chain::Connection
  Client = ReputableChat::ChainClient

  # Answers from a list: an exception is raised, anything else returned.
  class Script
    attr_reader :url

    def initialize(*answers) = (@answers = answers) && (@url = "http://chain.test")

    def genesis
      answer = @answers.shift
      answer.is_a?(Exception) ? raise(answer) : answer
    end
  end

  def wait(chain)
    said = []
    pauses = []
    result = Connection.wait_until_live(chain, say: ->(l) { said << l }, pause: ->(s) { pauses << s })
    [result, said, pauses]
  end

  # RULE (yours): a chat whose agnostic server is not listening, or is
  # catching up or stopped for a split, waits for it.
  def test_the_chat_waits_while_its_agnostic_server_is_not_live
    result, said, pauses = wait(Script.new(Client::NotReady.new("catching up"), Client::NotReady.new("refused"),
                                           { "hash" => "g" }))

    assert_equal({ "hash" => "g" }, result)
    assert_equal 2, pauses.size
    assert_match(/waiting for the agnostic server: catching up/, said.first, "it says what it is waiting for")
  end

  # RULE: anything but "not yet" is not waited out -- a wrong address answers
  # the same way every time.
  def test_an_answer_that_is_not_not_yet_is_raised
    assert_raises(Client::Unreachable) { wait(Script.new(Client::Unreachable.new("404"))) }
  end

  # RULE (yours): the chat opens no port until its agnostic server is live.
  def test_the_chat_opens_no_port_until_its_agnostic_server_is_live
    dir = Dir.mktmpdir("chat-spec-boot")
    chain_port = ChainServer.free_port
    port = ChainServer.free_port
    log = File.join(dir, "chat.log")
    pid = ChainServer.clean_env do
      Process.spawn(
        { "RACK_ENV" => "development", "SESSION_SECRET" => SecureRandom.hex(64), "ORIGIN" => nil,
          "DATABASE_URL" => "sqlite://#{dir}/chat.db", "IMAGE_ROOT" => "#{dir}/images",
          "CHAIN_URL" => "http://127.0.0.1:#{chain_port}",
          "HOST_SEED" => File.join(dir, "development", "host.seed"),
          "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") },
        "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{port}", "-q",
        chdir: ROOT, out: log, err: log
      )
    end

    sleep 6
    refute listening?(port), "the chat opened its port with no agnostic server"
    assert_match(/waiting for the agnostic server/, File.read(log))

    ChainServer.launch(dir, port: chain_port)
    assert(60.times.any? { listening?(port) || (sleep(0.5) && false) },
           "the chat never opened its port once the agnostic server was live; its log:\n#{File.read(log)}")
  ensure
    if pid
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end

  def listening?(port)
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue Errno::ECONNREFUSED
    false
  end
end
