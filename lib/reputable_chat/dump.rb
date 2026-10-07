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

    def render(sections = %w[users identities attestations messages emotes vaults])
      sections.each do |section|
        send(:"dump_#{section}")
        @out.puts
      end
    end

    private

    def short(pubkey) = pubkey.to_s[0, SHORT]

    # Names come from the signed identity declarations, so a key that has not
    # published one simply has no name.
    #
    # Seeded from the genesis record, which is itself an identity declaration
    # and the one that is never in this table. The genesis account is named on
    # nearly every line of a dump -- as an author, as an ack, as the first
    # person everybody scores -- and reading it as "(no declaration)" is the
    # least useful place for a blank.
    def names
      @names ||= genesis_name.merge(
        @db[:identities].select(:pubkey, :payload).each_with_object({}) do |row, map|
          map[row[:pubkey]] = parse(row[:payload])["handle"]
        end
      )
    end

    # A dump of a database is worth having even where the genesis record is not
    # readable, so this is a missing name rather than a failure.
    def genesis_name
      record = Genesis.current

      { record.pubkey => parse(record.payload)["handle"] }
    rescue StandardError
      {}
    end

    def named(pubkey) = "#{short(pubkey)} #{names[pubkey] || '(no declaration)'}"

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

    def dump_users
      rows = @db[:users].order(:created_at).all
      heading("USERS", rows.size)

      rows.each { |row| @out.puts format("  %-20s joined %s", named(row[:pubkey]), at(row[:created_at])) }
    end

    def dump_identities
      rows = @db[:identities].order(:pubkey).all
      heading("IDENTITY DECLARATIONS", rows.size)

      rows.each do |row|
        payload = parse(row[:payload])
        @out.puts format("  %-20s v%-3d %s", named(row[:pubkey]), row[:revision],
                         payload["icon"] ? "icon #{payload['icon'][0, 12]}…" : "no icon")
        @out.puts "      bio: #{clip(payload['bio'])}" unless payload["bio"].to_s.empty?
        @out.puts "      ack #{short_hash(payload['ack'])}" if payload["ack"]
        @out.puts "      note #{clip(payload['note'])}" if payload["note"]
      end
    end

    def dump_attestations
      rows = @db[:attestations].order(:pubkey).all
      heading("ATTESTATIONS", rows.size)

      rows.each do |row|
        payload = parse(row[:payload])
        scores = payload["scores"] || {}
        derived = payload["derived"] || {}

        @out.puts format("  %-20s v%-3d %d scored, cache of %d to %d hops",
                         named(row[:pubkey]), row[:revision], scores.size,
                         (derived["scores"] || {}).size, derived["hops"].to_i)
        @out.puts "      note #{clip(payload['note'])}" if payload["note"]
        @out.puts "      scores nobody" if scores.empty?
        scores.each { |target, score| @out.puts "      #{format('%-20s', named(target))} #{describe(score)}" }
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
      # the page. Sequel's `last` would hand them back reversed.
      rows = @db[:messages].order(Sequel.desc(:id)).limit(@limit).all.reverse
      heading("MESSAGES", @db[:messages].count)

      by_hash = ids_by_hash

      rows.each do |row|
        payload = parse(row[:payload])
        reply = row[:reply_to] ? " ↱ reply to ##{by_hash[row[:reply_to]] || '?'}" : ""
        @out.puts format("  #%-4d %-20s %s%s", row[:id], named(row[:pubkey]), at(row[:received_at]), reply)
        @out.puts "        #{clip(payload['body'])}"
        @out.puts "        ack #{ack_label(row[:ack], by_hash)}"
        # The note exists for a person reading the chain, so the tool for
        # reading the chain has to show it.
        @out.puts "        note #{clip(payload['note'])}" if payload["note"]
      end
    end

    def dump_emotes
      unless @db.table_exists?(:emotes)
        heading("EMOTES", 0)
        return
      end

      rows = @db[:emotes].order(:id).all
      heading("EMOTES", rows.size)

      by_hash = ids_by_hash
      rows.group_by { |row| row[:message] }.each do |target, group|
        @out.puts "  on ##{by_hash[target] || '?'}"
        group.group_by { |row| row[:emote] }.each do |emote, people|
          @out.puts "      #{emote} #{people.size}  #{people.map { |p| named(p[:pubkey]) }.join(', ')}"
        end
      end
    end

    # Everything on the chain names a message by its record hash, so this is
    # what turns an ack or a reply target back into something readable.
    def ids_by_hash
      @db[:messages].select(:id, :hash).to_h { |r| [r[:hash], r[:id]] }
    end

    # An ack naming a message this dump is showing reads as that message; anything else
    # is the genesis or a record this dump is not showing, so the hash itself
    # is the only honest thing to print.
    def ack_label(hash, by_hash)
      return "-" unless hash

      by_hash[hash] ? "##{by_hash[hash]}" : short_hash(hash)
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

      rows = @db[:vaults].order(:pubkey).all
      heading("VAULTS", rows.size)

      rows.each do |row|
        payload = parse(row[:payload])
        @out.puts format("  %-20s v%-3d %d bytes sealed (not readable from here)",
                         named(row[:pubkey]), row[:revision], payload["ciphertext"].to_s.bytesize)
      end
    end
  end
end
