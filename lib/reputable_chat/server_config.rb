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

    module_function

    # Only the keys named above are read, so an unrecognised key in the file is
    # ignored rather than reaching the server as a surprise.
    def load(path: PATH, env: ENV)
      file = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}

      DEFAULTS.keys.to_h do |key|
        override = env[ENV_KEYS.fetch(key)]
        value = present(override) || file[key] || DEFAULTS.fetch(key)

        [key, value]
      end
    end

    def present(value) = value.is_a?(String) && !value.strip.empty? ? value : nil
  end
end
