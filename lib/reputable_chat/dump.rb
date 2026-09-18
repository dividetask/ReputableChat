# frozen_string_literal: true

require "json"
require "time"
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

    def render(sections = %w[users configs messages reactions private])
      sections.each do |section|
        send(:"dump_#{section}")
        @out.puts
      end
    end

    private

    def short(pubkey) = pubkey.to_s[0, SHORT]

    # Display names come from the signed configs, so a key with no config
    # published yet simply has no name.
    def names
      @names ||= @db[:configs].select(:pubkey, :payload).each_with_object({}) do |row, map|
        map[row[:pubkey]] = parse(row[:payload]).dig("profile", "username")
      end
    end

    def named(pubkey) = "#{short(pubkey)} #{names[pubkey] || '(no profile)'}"

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

    def dump_configs
      rows = @db[:configs].order(:pubkey).all
      heading("PUBLIC CONFIGS", rows.size)

      rows.each do |row|
        payload = parse(row[:payload])
        profile = payload["profile"] || {}
        @out.puts format("  %-20s v%-3d %s", named(row[:pubkey]), row[:version],
                         profile["icon"] ? "icon #{profile['icon'][0, 12]}…" : "no icon")
        @out.puts "      bio: #{clip(profile['message'])}" unless profile["message"].to_s.empty?

        ratings = payload["ratings"] || {}
        @out.puts "      rates nobody" if ratings.empty?
        ratings.each { |target, rating| @out.puts "      #{format('%-20s', named(target))} #{describe(rating)}" }
      end
    end

    # The stored actions, not a score -- what the rating comes to depends on
    # whose config is reading it.
    def describe(rating)
      parts = []
      parts << "REPORTED" if rating["reported"]
      parts << "friend" if rating["friend"]
      parts << "cleared" if rating["cleared"]
      votes = rating["net_votes"].to_i
      parts << format("votes %+d", votes) unless votes.zero?

      parts.empty? ? "(nothing)" : parts.join(", ")
    end

    def dump_messages
      # The most recent, but printed oldest-first so a conversation reads down
      # the page. Sequel's `last` would hand them back reversed.
      rows = @db[:messages].order(Sequel.desc(:id)).limit(@limit).all.reverse
      heading("MESSAGES", @db[:messages].count)

      seq_by_signature = @db[:messages].select(:id, :signature).to_h { |r| [r[:signature], r[:id]] }

      rows.each do |row|
        payload = parse(row[:payload])
        reply = row[:reply_to] ? " ↱ reply to ##{seq_by_signature[row[:reply_to]] || '?'}" : ""
        @out.puts format("  #%-4d %-20s %s%s", row[:id], named(row[:author]), at(row[:received_at]), reply)
        @out.puts "        #{clip(payload['body'])}"
      end
    end

    def dump_reactions
      unless @db.table_exists?(:emotes)
        heading("REACTIONS", 0)
        return
      end

      rows = @db[:emotes].order(:id).all
      heading("REACTIONS", rows.size)

      ids = @db[:messages].select(:id, :signature).to_h { |r| [r[:signature], r[:id]] }
      rows.group_by { |row| row[:message] }.each do |signature, group|
        @out.puts "  on ##{ids[signature] || '?'}"
        group.group_by { |row| row[:emote] }.each do |emote, people|
          @out.puts "      #{emote} #{people.size}  #{people.map { |p| named(p[:author]) }.join(', ')}"
        end
      end
    end

    def dump_private
      unless @db.table_exists?(:private_configs)
        heading("PRIVATE CONFIGS", 0)
        return
      end

      rows = @db[:private_configs].order(:pubkey).all
      heading("PRIVATE CONFIGS", rows.size)

      rows.each do |row|
        payload = parse(row[:payload])
        settings = flatten(payload["settings"] || {})
        @out.puts format("  %-20s v%-3d voted on %d", named(row[:pubkey]), row[:version],
                         (payload["voted"] || []).size)
        @out.puts "      #{settings.empty? ? 'no pinned settings' : settings.join('  ')}"
      end
    end

    def flatten(hash, prefix = "")
      hash.flat_map do |key, value|
        path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
        value.is_a?(Hash) ? flatten(value, path) : ["#{path}=#{value}"]
      end
    end
  end
end
