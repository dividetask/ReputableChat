# frozen_string_literal: true

require "monitor"
require_relative "ledger"

module ReputableChat
  module Chain
    # The ledger and the database together: the records this server holds,
    # judged by the ledger and kept by the database.
    #
    # The genesis is the ledger's root and is never stored, since every server
    # has it as a committed file. The host account's declaration is a record
    # like any other once it joins, so it is stored the first time a server
    # boots with it.
    #
    # Another process may have stored records since this one last looked, so
    # every read and write first catches up from the database. Adding is under
    # a lock, so two records arriving at once are judged one after the other.
    class Book
      include MonitorMixin

      attr_reader :store

      def initialize(store, genesis:, host: nil, versions: Ledger::VERSIONS)
        super()
        @store = store
        @ledger = Ledger.new(genesis: genesis, versions: versions)
        @last = 0
        sync
        add(host) if host && !@ledger.include?(host.record_hash)
      end

      # The ledger, caught up. Readers use it directly.
      def ledger
        synchronize do
          sync
          @ledger
        end
      end

      # Judges a record and stores it if it is valid. Returns :ok or
      # :duplicate; raises Invalid with the rule it breaks.
      def add(record)
        synchronize do
          sync
          result = @ledger.add(record)
          return result if result == :duplicate

          @store.store_record(hash: record.record_hash, kind: record.kind, account: record.account,
                              payload: record.payload, signature: record.signature)
          # @last is left alone: another process may have stored a record
          # between the sync above and this insert, and the next sync must not
          # skip it. Reading this one back is a duplicate the ledger ignores.
          :ok
        end
      end

      private

      def sync
        loop do
          rows = @store.records_after(@last)
          return if rows.empty?

          rows.each do |row|
            @ledger.adopt(Record.parse(row[:payload], row[:signature]))
            @last = row[:id]
          end
        end
      end
    end
  end
end
