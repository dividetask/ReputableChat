# frozen_string_literal: true

require_relative "../chain_client"

module ReputableChat
  module Chain
    # Joining the chat to its agnostic server at boot.
    module Connection
      class Mismatch < StandardError; end

      module_function

      # Refuses to run against an agnostic server on another genesis -- the
      # chat's clients sign against the committed one, so every record they
      # made would be refused there, and for no reason they could see -- and
      # makes sure the host account's declaration is on the chain, since its
      # friends and records hang off it.
      def connect!(chain, genesis:, host: nil)
        theirs = chain.genesis["hash"]
        unless theirs == genesis.hash
          raise Mismatch, "the agnostic server at #{chain.url} runs genesis #{theirs}, but this chat's is " \
                          "#{genesis.hash}. Both must commit the same config/genesis/<environment>.json."
        end
        return unless host

        result = chain.submit(host.payload, host.signature)
        return if %w[accepted known].include?(result.status)

        raise Mismatch, "the agnostic server will not take this chat's host account " \
                        "(#{result.status}): #{(result.problems + result.missing).join('; ')}"
      end
    end
  end
end
