# frozen_string_literal: true

require "yaml"

module Agnostic
  # config/server.yml over built-in defaults, with a few environment variables
  # over both. Only the keys named in DEFAULTS are read.
  class Settings
    ROOT = File.expand_path("../..", __dir__)
    PATH = File.join(ROOT, "config/server.yml")

    DEFAULTS = {
      "data_dir" => "data",
      "database_url" => nil,
      "genesis" => "config/genesis/%{environment}.json",
      "host" => { "handle" => "Agnostic server", "bio" => "" },
      "heartbeat" => { "interval_seconds" => 600 },
      "records" => { "max_future_seconds" => 600 },
      "pending" => { "max_records" => 10_000, "max_age_seconds" => 3_600 },
      "peers" => {
        "urls" => [], "pull_interval_seconds" => 60, "push_interval_seconds" => 5,
        "fetch_missing" => 1_000, "timeout_seconds" => 10
      },
      "limits" => { "request_bytes" => 8_388_608, "batch_records" => 500, "page_records" => 500 }
    }.freeze

    # The least each number may be. The heartbeat floor is the rules' own.
    MINIMUMS = { %w[heartbeat interval_seconds] => 480 }.freeze

    attr_reader :environment

    def self.load(path: PATH, env: ENV)
      file = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      new(file, env: env)
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

    def data_dir = File.expand_path(File.join(dig("data_dir"), environment), ROOT)

    def database_url = dig("database_url") || "sqlite://#{File.join(data_dir, 'server.db')}"

    def genesis_path = File.expand_path(format(dig("genesis"), environment: environment), ROOT)

    def peers = Array(dig("peers", "urls")).map { |u| u.to_s.strip.chomp("/") }.reject(&:empty?).uniq

    def handle = dig("host", "handle").to_s

    def bio = dig("host", "bio").to_s

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
      @values["genesis"] = @env["GENESIS"] if present?(@env["GENESIS"])
      @values["peers"]["urls"] = @env["PEERS"].split(",") if present?(@env["PEERS"])
      interval = @env["HEARTBEAT_INTERVAL_SECONDS"]
      @values["heartbeat"]["interval_seconds"] = interval if present?(interval)
    end

    def present?(value) = value.is_a?(String) && !value.strip.empty?
  end
end
