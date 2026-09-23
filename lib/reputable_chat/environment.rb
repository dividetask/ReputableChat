# frozen_string_literal: true

module ReputableChat
  # Which deployment this is, and nothing else.
  #
  # It exists because the genesis account differs between them: development
  # runs on a published identity that anybody who has cloned the repository
  # can sign as, and production must not. See lib/reputable_chat/genesis.rb.
  module Environment
    DEVELOPMENT = "development"
    PRODUCTION  = "production"

    module_function

    # Anything that is not explicitly production is development. The failure
    # that matters is a production box quietly running development's published
    # key, so the default has to be the harmless one.
    def name = ENV.fetch("RACK_ENV", DEVELOPMENT)

    def production? = name == PRODUCTION
    def development? = !production?
  end
end
