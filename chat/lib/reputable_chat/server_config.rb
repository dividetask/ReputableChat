# frozen_string_literal: true

require "yaml"
require_relative "origin"
require_relative "environment"

module ReputableChat
  # Server settings from config/server.yml, with environment variables winning
  # so deployment tooling can inject values without editing a file baked into
  # an image.
  #
  # Secrets are not read from here. config/server.yml is in the repository, so
  # SESSION_SECRET stays in the environment.
  module ServerConfig
    PATH = File.expand_path("../../config/server.yml", __dir__)

    # No origin by default: the server takes it from each request. See Origin.
    DEFAULTS = {
      "origin" => nil,
      "database_url" => "sqlite://data/reputablechat.db",
      "image_root" => "data/images",
      "chain_url" => "http://localhost:9393",
      # The agnostic server's working seed: the chat and the agnostic server
      # beside it are one account. %{environment} is development or production.
      "host_seed" => "../server/data/%{environment}/host.seed",
      # Where other chat servers reach this one for files. Unset, this server
      # does not announce itself and nobody fetches from it.
      "url" => nil,
      # Whether other chat servers at private, loopback or link-local
      # addresses may be fetched from. Unset: yes in development, no otherwise.
      "allow_private_peers" => nil
    }.freeze

    ENV_KEYS = {
      "origin" => "ORIGIN",
      "database_url" => "DATABASE_URL",
      "image_root" => "IMAGE_ROOT",
      "chain_url" => "CHAIN_URL",
      "host_seed" => "HOST_SEED",
      "url" => "PUBLIC_URL",
      "allow_private_peers" => "ALLOW_PRIVATE_PEERS"
    }.freeze

    # Size limits are an operator's decision rather than a property of the
    # protocol, and they are served to clients so nothing has to discover a
    # ceiling by being refused. Each is overridden by its key in upper case.
    #
    # They apply to what this server's own clients send; the rules are the
    # agnostic server's to hold everyone to.
    LIMITS = {
      "vault_bytes" => 1_048_576,
      "image_bytes" => 262_144,
      "message_bytes" => 4_000,
      "bio_bytes" => 280,
      "notice_bytes" => 16_000,
      "attestation_bytes" => 1_048_576,
      "seen_entries" => 5_000,
      "vault_sync_seconds" => 3_600
    }.freeze

    module_function

    # Only the keys named above are read, so an unrecognised key in the file is
    # ignored rather than reaching the server as a surprise.
    def load(path: PATH, env: ENV)
      file = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}

      settings = DEFAULTS.keys.to_h do |key|
        override = env[ENV_KEYS.fetch(key)]
        value = present(override) || file[key] || DEFAULTS.fetch(key)

        [key, value]
      end

      root = File.expand_path("../..", __dir__)
      environment = Environment.name
      settings.merge("origin" => Origin.list(settings["origin"]),
                     "host_seed" => File.expand_path(format(settings["host_seed"], environment: environment), root),
                     "url" => present(settings["url"]&.to_s)&.chomp("/"),
                     "allow_private_peers" => flag(settings["allow_private_peers"], environment != Environment::PRODUCTION),
                     "limits" => limits(file["limits"] || {}, env))
    end

    # A limit that is absent, unparseable or not positive falls back to the
    # default rather than to zero: a zero here would refuse every save, and a
    # typo in a config file should not be able to do that silently.
    def limits(file, env)
      LIMITS.to_h do |key, fallback|
        raw = env[key.upcase] || file[key]
        parsed = Integer(raw.to_s, exception: false)

        [key, parsed&.positive? ? parsed : fallback]
      end
    end

    def flag(value, fallback)
      return fallback if value.nil? || value.to_s.strip.empty?

      %w[1 true yes].include?(value.to_s.strip.downcase)
    end

    def present(value) = value.is_a?(String) && !value.strip.empty? ? value : nil
  end
end
