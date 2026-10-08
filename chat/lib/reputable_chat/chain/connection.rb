# frozen_string_literal: true

require_relative "../chain_client"

module ReputableChat
  module Chain
    # Joining the chat to its agnostic server at boot.
    module Connection
      class Mismatch < StandardError; end

      module_function

      # Refuses to run against an agnostic server on another genesis: the
      # chat's clients sign against the committed one, so every record they
      # made would be refused there, and for no reason they could see.
      def connect!(chain, genesis:)
        theirs = chain.genesis["hash"]
        unless theirs == genesis.hash
          raise Mismatch, "the agnostic server at #{chain.url} runs genesis #{theirs}, but this chat's is " \
                          "#{genesis.hash}. Both must commit the same config/genesis/<environment>.json."
        end
      end
    end
  end
end
