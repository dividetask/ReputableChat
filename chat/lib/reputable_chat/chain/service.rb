# frozen_string_literal: true

require_relative "../cryptography/payload"
require_relative "envelope"

module ReputableChat
  module Chain
    # A chat server announcing itself to other chat servers, so they can fetch
    # the files its people uploaded (FilePeers).
    #
    # The announcement is a notice the chat client never signs, typed for the
    # chat and of kind "service", from the server's host account, carrying the
    # address in url:
    #
    #   type: reputablechat:notice:v0.001:chat   kind: service   url: https://chat.example.org
    #
    # Being typed for the chat is what makes it a chat server's: a host account
    # shared with a heartbeat server or another app announces each separately,
    # and the heartbeat server keeps its address on the identity declaration.
    # An account's latest one is current, and one without url withdraws it.
    # Nobody has to take it on trust -- another server fetches from it only
    # once it answers at that address as that account.
    module Service
      module_function

      # Publishes an announcement on the first boot that has an address, and
      # again only when the address changes. Returns the url announced, or
      # :unchanged.
      def announce!(chain:, mirror:, host:, url:)
        services = mirror.services
        announced = services.key?(host.account)
        return :unchanged if announced ? services[host.account] == url : url.nil?

        latest = chain.account(host.account)&.fetch("latest") || host.hash
        payload = Cryptography::Payload.record(
          "notice", app: Envelope::CHAT, id: host.account, pubkey: host.pubkey, kind: Envelope::SERVICE,
                    body: "", url: url, ack: [latest], ts: Time.now.to_i
        )
        canonical, signature = host.sign(payload)
        result = chain.submit(canonical, signature)
        unless %w[accepted known].include?(result.status)
          raise ChainClient::Unreachable, "the agnostic server refused this chat's announcement: " \
                                          "#{(result.problems + result.missing).join('; ')}"
        end

        mirror.sync
        url
      end
    end
  end
end
