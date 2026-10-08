# frozen_string_literal: true

require "json"
require "time"
require_relative "genesis"
require_relative "store/database"

module ReputableChat
  # A readable view of the database for an operator.
  #
  # Raw rows are mostly 43-character keys and signed JSON blobs, so this
  # decodes the payloads, resolves keys to display names, and shortens every
  # key to the same fingerprint the UI shows.
  class Dump
    SHORT = 8

    def initialize(store, out: $stdout, limit: 50, body_width: 68)
      @store = store
      @db = store.db
      @out = out
      @limit = limit
      @body_width = body_width
    end

    SECTIONS = %w[identities attestations messages reactions notices others vaults].freeze

    def render(sections = SECTIONS)
      sections.each do |section|
        send(:"dump_#{section}")
        @out.puts
      end
    end

    private

    def short(id) = id.to_s[0, SHORT]

    # Names come from the signed identity declarations, newest last, so an
    # account that has published none simply has no name.
    #
    # Seeded from the genesis record, which is itself an identity declaration
    # and the one that is never in the database. The genesis account is named
    # on nearly every line of a dump -- as an author, as an ack, as the first
    # account everybody rates -- and "(no declaration)" is the least useful
    # place for a blank.
    def names
      @names ||= genesis_name.merge(
        rows("identity").each_with_object({}) do |row, map|
          map[row[:account]] = parse(row[:payload])["title"]
        end
      )
    end

    # A dump of a database is worth having even where the genesis record is not
    # readable, so this is a missing name rather than a failure.
    def genesis_name
      record = Genesis.current

      { record.account => record.handle }
    rescue StandardError
      {}
    end

    # The working key each account declared first, for naming vaults, which
    # are kept by key rather than by account.
    def accounts_by_key
      @accounts_by_key ||= rows("identity").each_with_object({}) do |row, map|
        payload = parse(row[:payload])
        map[payload["pubkey"]] ||= row[:account] unless payload.key?("id")
      end
    end

    def rows(kind) = @db[:records].where(kind: kind).order(:id).all

    def number(hash) = (@numbers ||= @db[:records].select(:id, :hash).to_h { |r| [r[:hash], r[:id]] })[hash]

    def named(account) = "#{short(account)} #{names[account] || '(no declaration)'}"

    # Not an endless def: a trailing `rescue` on one binds to the class body
    # instead of the method, which quietly puts every later definition inside
    # the rescue branch so none of them get defined at all.
    def parse(payload)
      JSON.parse(payload.to_s)
    rescue JSON::ParserError
      {}
    end

    def at(epoch) = epoch ? Time.at(epoch).strftime("%Y-%m-%d %H:%M:%S") : "-"

    def clip(text)
      flat = text.to_s.gsub(/\s+/, " ").strip
      flat.length > @body_width ? "#{flat[0, @body_width - 1]}…" : flat
    end

    def heading(title, count)
      @out.puts "#{title} (#{count})"
      @out.puts "-" * 72
      @out.puts "  none" if count.zero?
    end

    def dump_identities
      list = rows("identity")
      heading("IDENTITY DECLARATIONS", list.size)

      list.each do |row|
        payload = parse(row[:payload])
        first = payload.key?("id") ? "" : " (first)"
        @out.puts format("  #%-4d %-20s %s%s", row[:id], named(row[:account]), at(row[:received_at]), first)
        @out.puts "        avatar #{payload['file'].first[0, 12]}…" if payload["file"]&.any?
        @out.puts "        bio: #{clip(payload['body'])}" unless payload["body"].to_s.empty?
        @out.puts "        ack #{acks(payload['ack'])}"
      end
    end

    def dump_attestations
      list = rows("attestation")
      heading("ATTESTATIONS", list.size)

      list.each do |row|
        payload = parse(row[:payload])
        scores = payload["scores"] || {}

        @out.puts format("  #%-4d %-20s %d rated, %d derived", row[:id], named(row[:account]),
                         scores.size, (payload["derived"] || {}).size)
        scores.each { |target, score| @out.puts "        #{format('%-20s', named(target))} #{describe(score)}" }
      end
    end

    # The published score, not the actions behind it. Those are private now --
    # they live in the author's vault, which this tool cannot read.
    def describe(score)
      reputation = score["reputation"].to_s
      trust = score["trust"].to_s
      label = reputation == "-1" ? "REPORTED" : "reputation #{reputation}"

      trust == "1" ? label : "#{label}, trust #{trust}"
    end

    def dump_messages
      # The most recent, but printed oldest-first so a conversation reads down
      # the page.
      list = @db[:records].where(kind: "message").order(Sequel.desc(:id)).limit(@limit).all.reverse
      heading("MESSAGES", @db[:records].where(kind: "message").count)

      list.each do |row|
        payload = parse(row[:payload])
        reply = payload["target"] ? " ↱ reply to #{acks(payload['target'])}" : ""
        @out.puts format("  #%-4d %-20s %s %s%s", row[:id], named(row[:account]), at(row[:received_at]),
                         payload["type"].to_s.split(":").drop(3).join(":"), reply)
        @out.puts "        #{clip(payload['body'])}"
        @out.puts "        ack #{acks(payload['ack'])}"
      end
    end

    def dump_reactions
      list = rows("reaction")
      heading("REACTIONS", list.size)

      list.group_by { |row| parse(row[:payload])["target"] }.each do |targets, group|
        @out.puts "  on #{acks(targets)}"
        group.group_by { |row| parse(row[:payload])["body"] }.each do |body, people|
          @out.puts "      #{body} #{people.size}  #{people.map { |p| named(p[:account]) }.join(', ')}"
        end
      end
    end

    def dump_notices
      list = rows("notice")
      heading("NOTICES", list.size)

      list.each do |row|
        payload = parse(row[:payload])
        @out.puts format("  #%-4d %-20s %s %s", row[:id], named(row[:account]), at(row[:received_at]), payload["kind"])
        @out.puts "        #{clip(payload['body'])}" unless payload["body"].to_s.empty?
      end
    end

    # Heartbeats and releases: records the chat does not show.
    def dump_others
      list = @db[:records].where(kind: %w[heartbeat release]).order(:id).all
      heading("HEARTBEATS AND RELEASES", list.size)

      list.each do |row|
        payload = parse(row[:payload])
        @out.puts format("  #%-4d %-20s %s %s, acks %d", row[:id], named(row[:account]),
                         at(row[:received_at]), payload["type"], payload["ack"].to_a.size)
      end
    end

    # A record this dump shows reads as its number; anything else is the
    # genesis or a record the database does not hold, so the hash itself is
    # the only honest thing to print.
    def acks(hashes)
      return "-" if hashes.to_a.empty?

      hashes.map { |h| number(h) ? "##{number(h)}" : short_hash(h) }.join(" ")
    end

    def short_hash(hash) = "#{hash[0, 12]}…"

    # Size and revision and nothing else, because there is nothing else to
    # show. The vault is sealed with a key derived from its owner\'s seed, which
    # the server does not have and this tool therefore cannot use. An operator
    # reading a dump should be able to see that directly.
    def dump_vaults
      unless @db.table_exists?(:vaults)
        heading("VAULTS", 0)
        return
      end

      list = @db[:vaults].order(:pubkey).all
      heading("VAULTS", list.size)

      list.each do |row|
        payload = parse(row[:payload])
        owner = accounts_by_key[row[:pubkey]]
        @out.puts format("  %-20s v%-3d %d bytes sealed (not readable from here)",
                         owner ? named(owner) : "key #{short(row[:pubkey])}", row[:revision],
                         payload["ciphertext"].to_s.bytesize)
      end
    end
  end
end
