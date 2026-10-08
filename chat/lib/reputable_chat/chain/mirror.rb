# frozen_string_literal: true

require "monitor"
require_relative "envelope"

module ReputableChat
  module Chain
    # The chat's copy of the part of the chain it shows: the records it keeps
    # (Envelope#relevant?), pulled from its agnostic server in the order the
    # server accepted them. The server holds everything and decides what is
    # valid; this is a working set, so the chat can list messages without
    # asking for the whole chain each time.
    #
    # Every read first catches up, so a record the server accepted -- from
    # this chat, another app or another server -- shows on the next read.
    class Mirror
      include MonitorMixin

      PAGE = 500

      def initialize(store, chain, chat_notices:)
        super()
        @store = store
        @chain = chain
        @chat_notices = chat_notices
      end

      def sync
        synchronize do
          loop do
            cursor = @store.chain_cursor
            records, following = @chain.records_since(cursor, limit: PAGE)
            records.each { |wire| keep(wire) }
            @store.save_chain_cursor(following)
            break if records.size < PAGE || following == cursor
          end
        end
        self
      end

      # The latest records of one kind made for the chat, oldest first.
      def chat(kind, limit) = sync.then { @store.chat_records(kind.to_s, limit) }

      def notices(account, limit: 100) = sync.then { @store.records_of(account, kind: "notice", limit: limit) }

      # The chat servers that have announced themselves: account => the url
      # of its latest service notice, or nil where that notice withdrew it.
      def services
        sync
        @store.chat_records("notice", 100_000).each_with_object({}) do |row, out|
          envelope = Envelope.parse(row[:payload], row[:signature])
          next unless envelope.service?

          out[envelope.account] = envelope["url"].is_a?(String) ? envelope["url"].chomp("/") : nil
        end
      end

      private

      def keep(wire)
        envelope = Envelope.parse(wire["payload"], wire["signature"])
        return unless envelope.relevant?(@chat_notices)

        @store.store_record(hash: envelope.record_hash, kind: envelope.kind, type: envelope["type"],
                            account: envelope.account, payload: envelope.payload, signature: envelope.signature)
      rescue Envelope::Unreadable
        nil
      end
    end
  end
end
