# frozen_string_literal: true

require_relative "../chain_client"

module ReputableChat
  module Chain
    # Joining the chat to its agnostic server at boot.
    module Connection
      class Mismatch < StandardError; end

      WAIT_SECONDS = 2
      SAY_EVERY = 30

      module_function

      # Waits until the agnostic server is live -- listening, caught up with
      # the chain and not stopped for a split -- since until then it cannot
      # check a record or say what anything's state is. Called before the
      # chat opens its port, so nobody reaches a chat that cannot work yet.
      # Says what it is waiting for now and then, and waits for as long as it
      # takes; anything but "not yet" (a 404, another genesis) is raised.
      def wait_until_live(chain, say: ->(line) { warn line }, pause: ->(s) { sleep s })
        waited = 0
        loop do
          return chain.genesis
        rescue ChainClient::NotReady => e
          say.call("waiting for the agnostic server: #{e.message}") if (waited % SAY_EVERY).zero?
          pause.call(WAIT_SECONDS)
          waited += WAIT_SECONDS
        end
      end

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
