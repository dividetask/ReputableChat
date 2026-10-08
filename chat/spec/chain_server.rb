# frozen_string_literal: true

require "fileutils"
require "net/http"
require "socket"
require "tmpdir"
require "reputable_chat/app"
require "reputable_chat/chain_client"
require "reputable_chat/genesis"
require "reputable_chat/host"

# A real agnostic server for the specs that need the chain: started once per
# run from ../server, on a free port with its own data directory, running the
# API alone (no heartbeats, no peers), and stopped when the run ends. Every
# spec shares it, so each makes accounts of its own rather than counting on an
# empty chain.
module ChainServer
  SERVER = File.expand_path("../../server", __dir__)

  module_function

  def url = @url ||= start

  # Where the server wrote its host account's working seed on first boot.
  def host_seed = File.join(@dir || (url && @dir), "development", "host.seed")

  # The chat's host account: the agnostic server's, derived once per run since
  # Argon2id is slow on purpose.
  def host = @host ||= ReputableChat::Host.join(ReputableChat::ChainClient.new(url), seed_path: host_seed)

  # The chat wired to it: the development genesis, which both commit, and a
  # fresh local database and mirror.
  def wire(app = ReputableChat::App, store: ReputableChat::Store::Database.new("sqlite:/"))
    app.store = store
    app.genesis = ReputableChat::Genesis.load(path: ReputableChat::Genesis.path("development"))
    app.chain = ReputableChat::ChainClient.new(url)
    app.host = host
    app.files = nil
    app.mirror = ReputableChat::Chain::Mirror.new(store, app.chain, chat_notices: ReputableChat::App::NOTICE_KINDS)
    app
  end

  def start
    dir = @dir = Dir.mktmpdir("chat-spec-chain")
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    log = File.join(dir, "server.log")
    env = { "RACK_ENV" => "development", "BACKGROUND" => "0", "DATA_DIR" => dir,
            "BUNDLE_GEMFILE" => File.join(SERVER, "Gemfile") }
    pid = clean_env do
      Process.spawn(env, "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{port}", "--quiet",
                    chdir: SERVER, out: log, err: log)
    end
    at_exit do
      Process.kill("TERM", pid)
      Process.wait(pid)
      FileUtils.rm_rf(dir)
    end

    address = "http://127.0.0.1:#{port}"
    120.times do
      return address if Net::HTTP.get_response(URI("#{address}/api")).is_a?(Net::HTTPSuccess)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
      sleep 0.5
    end
    raise "the agnostic server did not start; its log:\n#{File.read(log)}"
  end

  # The chat's bundle must not leak into the server's.
  def clean_env(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end
end
