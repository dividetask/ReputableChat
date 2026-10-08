# frozen_string_literal: true

# Signs a genesis record in the rules' own format: the developer's first
# identity declaration, carrying docs/project/rules/v0.001.md in its rules
# field, read straight from the file so the two cannot disagree.
#
#   bundle exec ruby script/generate_genesis.rb --key-file KEY [--out PATH]
#     [--handle Tim] [--bio TEXT] [--avatar <sha256>.<ext>] [--ts SECONDS]
#
# KEY holds the genesis account's Ed25519 private key as base64url: the raw
# Argon2id output the browser derives from the seed phrase. From a seed file,
# chat/script/derive_key.mjs prints it.
#
# Refuses to overwrite: a new genesis orphans every record that acknowledged
# the old one, which is the whole chain.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ed25519"
require "json"
require "optparse"
require "agnostic/host_account"
require "agnostic/keys"
require "agnostic/rules"

root = File.expand_path("..", __dir__)
options = {
  out: File.join(root, "config/genesis/#{ENV.fetch('RACK_ENV', 'development')}.json"),
  handle: "Tim", bio: "", ts: Time.now.to_i
}
OptionParser.new do |o|
  o.on("--key-file PATH") { |v| options[:key_file] = v }
  o.on("--out PATH") { |v| options[:out] = v }
  o.on("--handle TEXT") { |v| options[:handle] = v }
  o.on("--bio TEXT") { |v| options[:bio] = v }
  o.on("--avatar FILE") { |v| options[:avatar] = v }
  o.on("--ts SECONDS", Integer) { |v| options[:ts] = v }
end.parse!

abort "--key-file is required" unless options[:key_file]
abort "#{options[:out]} exists; a new genesis orphans the whole chain" if File.exist?(options[:out])

raw = Agnostic::Keys.decode(File.read(options[:key_file]).strip, Agnostic::Keys::KEY_BYTES)
abort "#{options[:key_file]} does not hold a 32-byte base64url key" unless raw

key = Ed25519::SigningKey.new(raw)
rules = File.read(File.join(root, "../docs/project/rules/#{Agnostic::Rules::VERSION}.md"), encoding: "UTF-8").strip
fields = {
  "ack" => [], "body" => options[:bio], "pubkey" => Agnostic::Keys.public_key(key), "rules" => rules,
  "title" => options[:handle], "ts" => options[:ts], "type" => "reputablechat:identity:#{Agnostic::Rules::VERSION}"
}
fields["file"] = [options[:avatar]] if options[:avatar]

record = Agnostic::HostAccount.sign(key, fields)
File.write(options[:out], "#{JSON.pretty_generate(record.to_wire)}\n")
puts "genesis #{record.digest} written to #{options[:out]}"
