# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "reputable_chat/app"
require "reputable_chat/server_config"
require "reputable_chat/genesis"
require "reputable_chat/host"

settings = ReputableChat::ServerConfig.load

ReputableChat::App.store  = ReputableChat::Store::Database.new(settings.fetch("database_url"))
ReputableChat::App.limits = settings.fetch("limits")
ReputableChat::App.images = ReputableChat::Store::Images.new(
  settings.fetch("image_root"), max_bytes: settings.fetch("limits").fetch("image_bytes")
)
ReputableChat::App.origins = settings.fetch("origin")
# Loaded at boot, and verified as it loads: a genesis that has been edited or
# truncated would otherwise put every client on a slightly different chain and
# show up only as signatures failing for no visible reason.
ReputableChat::App.genesis = ReputableChat::Genesis.current
# The genesis avatar is committed rather than uploaded, because the record
# naming it is read before any client has fetched anything. Adopting it into
# the image store keeps one serving path for every image.
ReputableChat::App.genesis.install_icon(ReputableChat::App.images)
# The chain is the agnostic server's. The chat refuses to run against one on
# another genesis, and keeps a copy of the records it shows.
ReputableChat::App.chain = ReputableChat::ChainClient.new(settings.fetch("chain_url"))
# Nothing happens, the port included, until the agnostic server is live:
# Puma loads this file before it binds.
ReputableChat::Chain::Connection.wait_until_live(ReputableChat::App.chain)
ReputableChat::Chain::Connection.connect!(ReputableChat::App.chain, genesis: ReputableChat::App.genesis)
ReputableChat::App.mirror = ReputableChat::Chain::Mirror.new(
  ReputableChat::App.store, ReputableChat::App.chain, chat_notices: ReputableChat::App::NOTICE_KINDS
)
# Every chat server has a host account, and it is the agnostic server's: the
# chat signs with that server's working seed, and refuses to run if the two
# are not one account.
ReputableChat::App.host = ReputableChat::Host.join(ReputableChat::App.chain, seed_path: settings.fetch("host_seed"))
# The agnostic server takes records only in uploads signed by an account on
# its chain; the chat signs its users' records, and its own, as the host
# account.
ReputableChat::App.chain.signer = ReputableChat::App.host
# Announced to other chat servers on the first boot with an address, and again
# only when the address changes, so they can fetch its people's files.
ReputableChat::Chain::Service.announce!(chain: ReputableChat::App.chain, mirror: ReputableChat::App.mirror,
                                        host: ReputableChat::App.host, url: settings.fetch("url"))
ReputableChat::App.files = ReputableChat::FilePeers.new(
  mirror: ReputableChat::App.mirror, chain: ReputableChat::App.chain, images: ReputableChat::App.images,
  host: ReputableChat::App.host, allow_private: settings.fetch("allow_private_peers"),
  require_https: ReputableChat::Environment.production?,
  missing_penalty: settings.fetch("file_peers").fetch("missing_penalty"),
  # What it finds counts toward each account's rating on the agnostic server.
  # A report says reached or not, so a server without the file is reported as
  # not reached until the chat sends adjustments instead
  # (docs/agnostic-server-requests.md, 1).
  reporter: lambda do |account, outcome|
    report = ReputableChat::App.host.contact_report(account, reached: outcome == :reached)
    ReputableChat::App.chain.report_contact(*report)
  end
)

run ReputableChat::App.freeze.app
