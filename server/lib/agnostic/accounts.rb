# frozen_string_literal: true

require "set"
require_relative "view"

module Agnostic
  # What an app asks of the chain about records and accounts, answered as seen
  # by everything this server holds rather than by any one record: a record's
  # state, which account a key signs for, and an account's newest records.
  #
  # The rules say how a record is judged; these say where it stands now, and
  # an app reads them to decide what to show. They change as records arrive,
  # so an app asks again rather than keeping an answer.
  class Accounts
    # A view that holds every stored record.
    EVERYTHING = Object.new.tap { |o| o.define_singleton_method(:include?) { |_| true } }.freeze

    STATES = %w[valid tentative disputed confirmed void].freeze

    def initialize(store:, genesis:)
      @store = store
      @genesis = genesis
    end

    # One of STATES (section 1), or nil for a record this server does not hold.
    def state(hash) = states([hash])[hash]

    # Several at once, sharing one view of the chain, which is most of the cost.
    def states(hashes)
      view = everything
      hashes.to_h { |hash| [hash, (record = @store.fetch(hash)) && state_in(view, record)] }
    end

    private

    def state_in(view, record)
      hash = record.digest
      keys = view.keys(record.account)
      return "void" if keys.void?(hash)
      return "void" if record.signer && keys.void_keys.include?(record.signer)
      return "void" if spend_lost?(record, view)
      return "confirmed" if keys.confirmed_records.include?(hash)
      return "disputed" if view.disputed?(record.account)

      field = KeyState::FIELDS[record.notice_kind]
      return "tentative" if field && keys.tentative[field].any? { |c| c.digest == hash }

      "valid"
    end

    public

    # The account a working key signs for: the oldest that declared it or
    # moved to it and may still sign with it. nil when none does.
    def account_for(pubkey)
      rows = @store.db[:records].where(kind: "identity").or(notice_kind: "key-change").order(:seq).all
      candidates = rows.map { |row| @store.fetch(row[:hash]) }.filter_map do |r|
        r.account if (r.first_declaration? && r["pubkey"] == pubkey) || (r.notice_kind == "key-change" && r["body"] == pubkey)
      end

      view = everything
      candidates.uniq.find { |account| view.keys(account).allowed("pubkey").include?(pubkey) }
    end

    # An account's newest identity declaration and attestation -- the one no
    # other of its kind has in its history, and of several such the latest
    # signed -- and the record it accepted from the account last.
    def summary(account)
      records = @store.by_account(account)
      return nil if records.empty?

      {
        "account" => account,
        "declaration" => newest(records.select { |r| r.kind == "identity" })&.to_wire,
        "attestation" => newest(records.select { |r| r.kind == "attestation" })&.to_wire,
        "latest" => records.max_by(&:seq).digest
      }
    end

    private

    def everything = View.new(store: @store, histories: Histories.new(@store), hashes: EVERYTHING, genesis: @genesis)

    def newest(records)
      return nil if records.empty?

      histories = Histories.new(@store)
      tips = records.reject { |r| records.any? { |o| o.digest != r.digest && histories.ancestor?(r.digest, o.digest) } }
      tips.max_by { |r| [r.ts.to_i, r.digest] }
    end

    # The issuer endorsed the other spend of an output this one spends.
    def spend_lost?(record, view)
      spent = Array(record.transfer&.fetch("in", nil))
      return false if spent.empty?

      issuer = record.transfer["currency"]
      spent.any? do |output|
        (view.spenders(output, record.account).map(&:digest) - [record.digest]).any? do |rival|
          view.endorsers(rival).any? { |e| e.account == issuer }
        end
      end
    end
  end
end
