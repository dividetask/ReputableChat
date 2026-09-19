# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../brain"

module ReputableChat
  module Bot
    module Brain
      # A small local model behind an OpenAI-compatible endpoint, which is what
      # both `ollama serve` and llama.cpp's `llama-server` expose.
      #
      # One server holds the model; every bot process talks to it over HTTP. A
      # model per bot would be the same weights in memory N times, and these
      # bots ask for about forty tokens an hour each -- nowhere near enough
      # work to justify a second copy.
      class Llm
        def initialize(persona:, random: Random.new, links: [], logger: nil)
          # The category first, then what is particular to this bot. A persona
          # can therefore be nothing more than a name and a voice.
          @briefing = persona.briefing
          @settings = persona.llm
          @random   = random
          @links    = links
          @logger   = logger
          @uri      = URI.parse(@settings.fetch("endpoint"))
        end

        def compose(context)
          reply = ask(prompt_for(context))

          Brain.clean(reply, name: context.name, links: @links, random: @random)
        end

        private

        # Terse on purpose. A 270M model follows one short instruction and
        # starts improvising if you give it three.
        def prompt_for(context)
          parts = []

          unless context.recent.empty?
            transcript = context.recent.map { |(name, body)| "#{name}: #{body}" }.join("\n")
            parts << "Messages in ##{context.room}, newest last:\n#{transcript}"
          end

          parts << if context.kind == :reply && context.target
                     "Reply to #{context.target_name}, who said: #{context.target.body}\n" \
                     "Write one short line as #{context.name}. No name prefix, no quotes."
                   else
                     "Write one short new message as #{context.name}. " \
                     "No name prefix, no quotes."
                   end

          parts.join("\n\n")
        end

        def ask(prompt)
          body = {
            "model" => @settings.fetch("model"),
            "messages" => [
              { "role" => "system", "content" => @briefing },
              { "role" => "user", "content" => prompt }
            ],
            "max_tokens" => @settings.fetch("max_tokens"),
            "temperature" => @settings.fetch("temperature"),
            # One line is the whole request, and a small model will happily
            # carry on inventing both sides of the conversation.
            "stop" => ["\n"]
          }

          post(body).dig("choices", 0, "message", "content")
        rescue StandardError => e
          # A model that is down turns every post into a read rather than
          # killing a bot that has been running for days. Logged, because
          # silence here looks exactly like a quiet persona.
          @logger&.call("llm: #{e.class}: #{e.message}")
          nil
        end

        def post(body)
          request = Net::HTTP::Post.new(@uri)
          request["Content-Type"] = "application/json"
          request["Authorization"] = "Bearer #{@settings['api_key']}" if @settings["api_key"]
          request.body = JSON.generate(body)

          timeout  = @settings.fetch("timeout_seconds")
          response = Net::HTTP.start(@uri.hostname, @uri.port,
                                     use_ssl: @uri.scheme == "https",
                                     open_timeout: 10, read_timeout: timeout) do |http|
            http.request(request)
          end

          raise "#{response.code} #{response.body.to_s[0, 200]}" unless response.code.to_i.between?(200, 299)

          JSON.parse(response.body)
        end
      end
    end
  end
end
