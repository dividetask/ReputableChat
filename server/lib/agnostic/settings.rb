# frozen_string_literal: true

require "bigdecimal"
require "yaml"

module Agnostic
  # config/server.yml over built-in defaults, with a few environment variables
  # over both. Only the keys named in DEFAULTS are read.
  class Settings
    ROOT = File.expand_path("../..", __dir__)
    PATH = File.join(ROOT, "config/server.yml")

    DEFAULTS = {
      "data_dir" => "data",
      # Where the host account lives. Unset, in the data directory; the
      # committed config/server.yml sets it outside both apps, since the apps
      # beside this server sign as the same account.
      "host_dir" => nil,
      "database_url" => nil,
      "genesis" => "config/genesis/%{environment}.json",
      "host" => { "handle" => "Agnostic server", "bio" => "", "url" => nil, "seed_words" => 12 },
      "heartbeat" => { "interval_seconds" => 600 },
      "records" => { "max_future_seconds" => 600 },
      "pending" => { "max_records" => 10_000, "max_age_seconds" => 3_600, "sweep_seconds" => 300 },
      "peers" => {
        "urls" => [], "max_clock_skew_seconds" => 600, "ignore_seconds" => 604_800,
        "forget_after_seconds" => 604_800, "max_learned" => 100,
        "retry" => { "first_seconds" => 600, "multiplier" => "2", "max_seconds" => 86_400 }, "fetch_missing" => 1_000, "timeout_seconds" => 10
      },
      "ratings" => {
        "never_reached" => "-1", "went_offline" => "-0.01", "reliable_ratio" => "0.9",
        "reliable" => { "after_seconds" => 10_368_000, "rating" => "0.01" },
        "established" => { "after_seconds" => 31_536_000, "rating" => "0.02" }
      },
      "limits" => { "request_bytes" => 8_388_608, "batch_records" => 500, "page_records" => 500, "sweep_records" => 500,
                     "sweep_requests_per_minute" => 60 }
    }.freeze

    # The least each number may be. The heartbeat floor is the rules' own.
    # The least each number may be. The heartbeat floor is the rules' own; the
    # seed floor is the chat's, below which a phrase is guessable.
    MINIMUMS = { %w[heartbeat interval_seconds] => 480, %w[host seed_words] => 8 }.freeze

    attr_reader :environment

    LOCAL = "settings.yml"

    # config/server.yml, then what `rake setup` wrote for this server into
    # its data directory, which is not committed.
    def self.load(path: PATH, env: ENV)
      file = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      local = File.join(new(file, env: env).data_dir, LOCAL)
      file = deep_merge(file, YAML.safe_load_file(local) || {}) if File.exist?(local)
      new(file, env: env)
    end

    def self.deep_merge(a, b)
      a.merge(b) { |_, x, y| x.is_a?(Hash) && y.is_a?(Hash) ? deep_merge(x, y) : y }
    end

    def initialize(file = {}, env: ENV)
      @env = env
      @environment = env.fetch("RACK_ENV", "development")
      @values = merge(DEFAULTS, file)
      override
    end

    def dig(*keys) = @values.dig(*keys)

    def integer(*keys)
      default = DEFAULTS.dig(*keys)
      parsed = Integer(dig(*keys).to_s, exception: false)
      parsed = default unless parsed&.positive?
      [parsed, MINIMUMS.fetch(keys, 0)].max
    end

    # A decimal setting, never below its minimum.
    def decimal(*keys, minimum:)
      value = begin
        BigDecimal(dig(*keys).to_s)
      rescue ArgumentError, TypeError
        nil
      end
      value && value >= minimum ? value : BigDecimal(DEFAULTS.dig(*keys).to_s)
    end

    def data_dir = File.expand_path(File.join(dig("data_dir"), environment), ROOT)

    def host_dir
      dir = dig("host_dir")
      present?(dir) ? File.expand_path(File.join(dir, environment), ROOT) : data_dir
    end

    def database_url = dig("database_url") || "sqlite://#{File.join(data_dir, 'server.db')}"

    def genesis_path = File.expand_path(format(dig("genesis"), environment: environment), ROOT)

    def peers = Array(dig("peers", "urls")).map { |u| u.to_s.strip.chomp("/") }.reject(&:empty?).uniq

    def handle = dig("host", "handle").to_s

    def bio = dig("host", "bio").to_s

    # Where other servers reach this one, declared in the host account's
    # identity so a peer can find it by account. Unset, peers cannot push to
    # this server; it still syncs with the peers it names.
    def url
      value = dig("host", "url").to_s.strip
      value.empty? ? nil : value.chomp("/")
    end

    private

    def merge(defaults, file)
      defaults.to_h do |key, value|
        given = file.is_a?(Hash) ? file[key] : nil
        [key, value.is_a?(Hash) ? merge(value, given) : (given.nil? ? value : given)]
      end
    end

    def override
      @values["database_url"] = @env["DATABASE_URL"] if present?(@env["DATABASE_URL"])
      @values["data_dir"] = @env["DATA_DIR"] if present?(@env["DATA_DIR"])
      @values["host_dir"] = @env["HOST_DIR"] if present?(@env["HOST_DIR"])
      @values["genesis"] = @env["GENESIS"] if present?(@env["GENESIS"])
      @values["host"]["url"] = @env["HOST_URL"] if present?(@env["HOST_URL"])
      @values["peers"]["urls"] = @env["PEERS"].split(",") if present?(@env["PEERS"])
      interval = @env["HEARTBEAT_INTERVAL_SECONDS"]
      @values["heartbeat"]["interval_seconds"] = interval if present?(interval)
    end

    def present?(value) = value.is_a?(String) && !value.strip.empty?
  end
end
