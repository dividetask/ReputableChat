# frozen_string_literal: true

require "yaml"
require "bigdecimal"

module ReputableChat
  # Layered configuration.
  #
  # Three layers resolve in order: a user's explicitly pinned value, then the
  # current server default, then the hardcoded fallback. A key that is absent
  # or blank in the user layer tracks the default, so editing config/*.yml
  # moves every user who never pinned that setting and nobody who did.
  class Config
    class MissingKey < StandardError; end

    DEFAULT_PATH = File.expand_path("../../config/reputation.yml", __dir__)

    attr_reader :defaults, :overrides

    def self.load(path: DEFAULT_PATH, overrides: {})
      new(defaults: YAML.safe_load_file(path), overrides: overrides || {})
    end

    def initialize(defaults:, overrides: {})
      @defaults  = deep_freeze(defaults)
      @overrides = overrides || {}
    end

    # Returns a config with the same defaults but a different user layer.
    def for_user(overrides)
      self.class.new(defaults: @defaults, overrides: overrides || {})
    end

    # Dotted path lookup: fetch("vote_curve.cap")
    def fetch(path)
      pinned = dig_path(@overrides, path)
      return pinned unless blank?(pinned)

      value = dig_path(@defaults, path)
      raise MissingKey, "no value or default for #{path.inspect}" if value.nil?

      value
    end

    def fetch_or_nil(path)
      fetch(path)
    rescue MissingKey
      nil
    end

    def decimal(path) = BigDecimal(fetch(path).to_s)
    def integer(path) = Integer(fetch(path))

    # Every entry under `constants:`, as BigDecimals, for formula evaluation.
    def constants
      merged = (@defaults["constants"] || {}).merge(
        (@overrides["constants"] || {}).reject { |_, v| blank?(v) }
      )
      merged.transform_values { |v| BigDecimal(v.to_s) }
    end

    def scale = integer("precision.scale")

    private

    def dig_path(hash, path)
      path.split(".").reduce(hash) do |node, key|
        return nil unless node.is_a?(Hash)

        node[key]
      end
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def deep_freeze(obj)
      case obj
      when Hash  then obj.each_value { |v| deep_freeze(v) }.freeze
      when Array then obj.each { |v| deep_freeze(v) }.freeze
      else obj.freeze
      end
    end
  end
end
