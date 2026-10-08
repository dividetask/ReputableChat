# frozen_string_literal: true

# Signs a genesis record in the rules' own format: the developer's first
# identity declaration, carrying docs/project/rules/v0.001.md in its rules
# field, read straight from the file so the two cannot disagree.
#
#   bundle exec ruby script/generate_genesis.rb --seed-file SEED [--master-seed-file SEED]
#     [--out PATH] [--handle Tim] [--bio TEXT] [--avatar <sha256>.<ext>] [--ts SECONDS]
#
# SEED holds the genesis account's seed phrase, from which the key is derived
# exactly as the browser derives it; the master seed phrase, if given, is
# declared as mpubkey. --key-file KEY takes the derived Ed25519 private key as
# base64url instead of a phrase.
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
require "agnostic/seed"

root = File.expand_path("..", __dir__)
options = {
  out: File.join(root, "config/genesis/#{ENV.fetch('RACK_ENV', 'development')}.json"),
  handle: "Tim", bio: "", ts: Time.now.to_i
}
OptionParser.new do |o|
  o.on("--seed-file PATH") { |v| options[:seed_file] = v }
  o.on("--master-seed-file PATH") { |v| options[:master_seed_file] = v }
  o.on("--key-file PATH") { |v| options[:key_file] = v }
  o.on("--out PATH") { |v| options[:out] = v }
  o.on("--handle TEXT") { |v| options[:handle] = v }
  o.on("--bio TEXT") { |v| options[:bio] = v }
  o.on("--avatar FILE") { |v| options[:avatar] = v }
  o.on("--ts SECONDS", Integer) { |v| options[:ts] = v }
end.parse!

abort "--seed-file or --key-file is required" unless options[:seed_file] || options[:key_file]
abort "#{options[:out]} exists; a new genesis orphans the whole chain" if File.exist?(options[:out])

key = if options[:seed_file]
        Agnostic::Seed.signing_key(File.read(options[:seed_file]))
      else
        raw = Agnostic::Keys.decode(File.read(options[:key_file]).strip, Agnostic::Keys::KEY_BYTES)
        abort "#{options[:key_file]} does not hold a 32-byte base64url key" unless raw
        Ed25519::SigningKey.new(raw)
      end
rules = File.read(File.join(root, "../docs/project/rules/#{Agnostic::Rules::VERSION}.md"), encoding: "UTF-8").strip
fields = {
  "ack" => [], "body" => options[:bio], "pubkey" => Agnostic::Keys.public_key(key), "rules" => rules,
  "title" => options[:handle], "ts" => options[:ts], "type" => "reputablechat:identity:#{Agnostic::Rules::VERSION}"
}
fields["file"] = [options[:avatar]] if options[:avatar]
if options[:master_seed_file]
  fields["mpubkey"] = Agnostic::Keys.public_key(Agnostic::Seed.signing_key(File.read(options[:master_seed_file])))
end

record = Agnostic::HostAccount.sign(key, fields)
File.write(options[:out], "#{JSON.pretty_generate(record.to_wire)}\n")
puts "genesis #{record.digest} written to #{options[:out]}"
