# frozen_string_literal: true

require "yaml"

module ReputableChat
  # Server settings from config/server.yml, with environment variables winning
  # so deployment tooling can inject values without editing a file baked into
  # an image.
  #
  # Secrets are not read from here. config/server.yml is in the repository, so
  # SESSION_SECRET stays in the environment.
  module ServerConfig
    PATH = File.expand_path("../../config/server.yml", __dir__)

    DEFAULTS = {
      "origin" => "http://localhost:9292",
      "database_url" => "sqlite://data/reputablechat.db",
      "image_root" => "data/images"
    }.freeze

    ENV_KEYS = {
      "origin" => "ORIGIN",
      "database_url" => "DATABASE_URL",
      "image_root" => "IMAGE_ROOT"
    }.freeze

    # Size limits are an operator's decision rather than a property of the
    # protocol, and they are served to clients so nothing has to discover a
    # ceiling by being refused. Each is overridden by its key in upper case.
    LIMITS = {
      "vault_bytes" => 1_048_576,
      "image_bytes" => 262_144,
      "message_bytes" => 4_000,
      "notice_bytes" => 16_000,
      "note_bytes" => 2_000,
      "seen_entries" => 5_000
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

      settings.merge("limits" => limits(file["limits"] || {}, env))
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

    def present(value) = value.is_a?(String) && !value.strip.empty? ? value : nil
  end
end
