# frozen_string_literal: true

require "agnostic/record"

# The signed example chain in docs/project/rules/, read as records in the order
# the file lists them.
module Examples
  ROOT     = File.expand_path("../../..", __dir__)
  EXAMPLES = File.join(ROOT, "docs/project/rules/v0.001-examples.md")
  BROKEN   = File.expand_path("../fixtures/examples_broken.md", __dir__)
  PATTERN  = /```\npayload:   (.+?)\nsignature: (\S+)\nhash:      (\S+)\n```/

  module_function

  def records(path = EXAMPLES)
    File.read(path, encoding: "UTF-8").scan(PATTERN).map do |payload, signature, hash|
      record = Agnostic::Record.new(payload: payload, signature: signature)
      raise "#{hash} does not hash to itself" unless record.digest == hash

      record
    end
  end

  # The broken fixture's records by their heading.
  def broken
    File.read(BROKEN, encoding: "UTF-8").split(/^## /).drop(1).to_h do |section|
      name = section.lines.first.strip
      [name, records_in(section).first]
    end
  end

  def records_in(text)
    text.scan(PATTERN).map { |payload, signature, _| Agnostic::Record.new(payload: payload, signature: signature) }
  end

  # The example keys: each private half is the SHA-256 of a fixed phrase.
  def signing_key(name)
    require "digest"
    require "ed25519"
    Ed25519::SigningKey.new(Digest::SHA256.digest("reputablechat example key: #{name}"))
  end
end
