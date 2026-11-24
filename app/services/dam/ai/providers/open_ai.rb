# frozen_string_literal: true

module Dam
  module Ai
    module Providers
      # OpenAI Chat Completions, via the ruby-openai gem. Also serves OpenAI-compatible
      # servers (Ollama, vLLM, LM Studio, OpenRouter, ...) when given a base URL; their
      # API key is optional.
      class OpenAi < Base
        REQUEST_TIMEOUT = 120 # seconds

        def initialize(temperature: ENV.fetch("OPENAI_TEMPERATURE", "0.3").to_f, **options)
          super(**options)
          require_sdk("openai", "ruby-openai")
          @temperature = temperature
          client_options = { access_token: @api_key.presence || "none", request_timeout: REQUEST_TIMEOUT }
          client_options[:uri_base] = @base_url if @base_url.present?
          @client = ::OpenAI::Client.new(**client_options)
        end

        private

        def request(prompt:, image_bytes:, mime:, schema:, max_tokens:)
          data_url = "data:#{mime};base64,#{Base64.strict_encode64(image_bytes)}"
          response = @client.chat(parameters: {
            model: model,
            temperature: @temperature,
            max_tokens: max_tokens,
            # json_object (not json_schema) is the JSON mode compatible servers support
            # most widely; the prompt describes the shape.
            response_format: { type: "json_object" },
            messages: [ {
              role: "user",
              content: [
                { type: "text", text: "#{prompt}\n\nRespond with JSON matching this schema: #{schema.to_json}" },
                { type: "image_url", image_url: { url: data_url, detail: "low" } }
              ]
            } ]
          })

          choice = response.dig("choices", 0) || {}
          if choice["finish_reason"] == "length"
            raise InvalidResponseError, "#{self.class}: response cut off at max_tokens"
          end
          refusal = choice.dig("message", "refusal")
          raise RefusalError, "#{self.class}: model declined: #{refusal}" if refusal.present?

          usage = response["usage"] || {}
          Result.new(
            data: parse_json!(choice.dig("message", "content")),
            input_tokens: usage["prompt_tokens"],
            output_tokens: usage["completion_tokens"],
            model: response["model"] || model
          )
        end

        # ruby-openai raises Faraday errors for HTTP and network failures.
        def retryable?(error)
          return true if defined?(::Faraday::TooManyRequestsError) && error.is_a?(::Faraday::TooManyRequestsError)
          return true if defined?(::Faraday::ServerError) && error.is_a?(::Faraday::ServerError)
          return true if defined?(::Faraday::ConnectionFailed) && error.is_a?(::Faraday::ConnectionFailed)
          return true if defined?(::Faraday::TimeoutError) && error.is_a?(::Faraday::TimeoutError)

          false
        end
      end
    end
  end
end
