# frozen_string_literal: true

require "digest"
require "fileutils"

module ReputableChat
  module Store
    # Content-addressed image storage. A file's name IS the SHA-256 of its
    # bytes, so the server derives it rather than trusting a claimed name, and
    # any reader can re-hash what they fetched to confirm it is what the author
    # signed.
    class Images
      MAX_BYTES = 262_144

      # Sniffed from the bytes, never from a client-supplied extension or
      # content type. SVG is deliberately absent: it is a script-bearing
      # document, not an image.
      MAGIC = {
        "png"  => ["\x89PNG\r\n\x1A\n".b],
        "jpg"  => ["\xFF\xD8\xFF".b],
        "gif"  => ["GIF87a".b, "GIF89a".b],
        "webp" => [] # handled below: RIFF....WEBP
      }.freeze

      CONTENT_TYPES = {
        "png" => "image/png", "jpg" => "image/jpeg",
        "gif" => "image/gif", "webp" => "image/webp"
      }.freeze

      NAME = /\A[0-9a-f]{64}\.(png|jpg|gif|webp)\z/

      attr_reader :max_bytes

      def initialize(root, max_bytes: MAX_BYTES)
        @root = root
        @max_bytes = max_bytes
        FileUtils.mkdir_p(@root)
      end

      # :too_large, :unsupported, or the filename.
      def store(bytes)
        raw = bytes.to_s.b
        return :too_large if raw.bytesize > max_bytes || raw.empty?

        extension = sniff(raw) or return :unsupported

        filename = "#{Digest::SHA256.hexdigest(raw)}.#{extension}"
        target = File.join(@root, filename)
        File.binwrite(target, raw) unless File.exist?(target)

        filename
      end

      def sniff(raw)
        return "webp" if raw.start_with?("RIFF".b) && raw[8, 4] == "WEBP".b

        MAGIC.each do |extension, prefixes|
          return extension if prefixes.any? { |p| raw.start_with?(p) }
        end
        nil
      end

      # The name pattern is the only path check needed -- 64 hex plus a known
      # extension cannot traverse anywhere.
      def read(filename)
        return nil unless valid_name?(filename)

        path = File.join(@root, filename)
        File.exist?(path) ? File.binread(path) : nil
      end

      def valid_name?(filename) = filename.is_a?(String) && filename.match?(NAME)
      def content_type(filename) = CONTENT_TYPES.fetch(File.extname(filename).delete("."), "application/octet-stream")
    end
  end
end
