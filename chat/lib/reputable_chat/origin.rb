# frozen_string_literal: true

require "uri"

module ReputableChat
  # The origin a login signature is bound to: scheme, host and port, spelled
  # the way a browser's `window.location.origin` spells it.
  #
  # An operator may list the origins a server answers to. When none are
  # listed, the server takes its origin from each request, so the same code
  # runs at any domain or address without configuration. That gives up one
  # thing: a client that is not a browser (script/tim.rb) pointed at a
  # malicious server can have its login relayed to a real one, since whoever
  # sends the request chooses its Host. A browser loses nothing by it -- a
  # malicious server serves its own page and reads the seed as it is typed --
  # and replaying a harvested login is already stopped by the server-issued,
  # single-use nonce.
  module Origin
    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    module_function

    # Configured origins, from a YAML string or list, or an environment variable
    # holding one or more separated by commas or spaces. Anything that does not
    # parse as an http(s) origin is refused at boot rather than at the first
    # login, where it would read as a bad signature.
    def list(value)
      entries = value.is_a?(Array) ? value : value.to_s.split(/[\s,]+/)
      entries.map(&:to_s).reject { |entry| entry.strip.empty? }.map { |entry| normalize!(entry) }.uniq.freeze
    end

    def normalize!(text)
      normalize(text) or raise ArgumentError, "not an http(s) origin: #{text.inspect}"
    end

    # Scheme and host lowercased, a default port dropped, and nothing after the
    # authority -- a trailing slash in a config file must not break every login.
    def normalize(text)
      uri = URI.parse(text.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?

      scheme = uri.scheme.downcase
      port = uri.port == DEFAULT_PORTS[scheme] ? "" : ":#{uri.port}"
      "#{scheme}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    # The origin the browser used, rebuilt from the request. Behind a reverse
    # proxy the app sees the proxy's connection, so the proxy's X-Forwarded-*
    # headers are believed. Believing them costs nothing extra: whoever sends a
    # request already chooses its Host. Of a comma separated list the first
    # entry is the one the outermost proxy saw, which is the browser's.
    def from_request(request)
      scheme = first(request.get_header("HTTP_X_FORWARDED_PROTO")) || request.scheme
      authority = first(request.get_header("HTTP_X_FORWARDED_HOST")) || request.host_with_port

      normalize("#{scheme}://#{authority}")
    end

    def first(header)
      value = header.to_s.split(",").first.to_s.strip
      value.empty? ? nil : value
    end
  end
end
