# frozen_string_literal: true

module Dam
  module Ai
    module Providers
      # Anthropic Claude Messages API, via the official "anthropic" gem.
      #
      # Structured outputs (output_config.format) guarantee the reply matches the JSON
      # schema. Server-side fallback ("default") lets the API retry a declined request on
      # a fallback model; on models without fallbacks the request runs as is.
      class Anthropic < Base
        FALLBACK_BETA = "server-side-fallback-2026-07-01"
        # Image types the Messages API accepts, and its size limit per image.
        SUPPORTED_MIME_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
        MAX_IMAGE_BYTES = 5 * 1024 * 1024
        # Current Claude models think before answering, and thinking counts toward
        # max_tokens; a floor keeps short structured replies from being cut off.
        MIN_MAX_TOKENS = 4096

        def initialize(**options)
          super
          require_sdk("anthropic", "anthropic")
          # Retries are handled by Base#with_retries, so they also go through the host's
          # ai_request_wrapper.
          client_options = { max_retries: 0 }
          client_options[:api_key] = @api_key if @api_key.present?
          client_options[:base_url] = @base_url if @base_url.present?
          @client = ::Anthropic::Client.new(**client_options)
        end

        private

        def request(prompt:, image_bytes:, mime:, schema:, max_tokens:)
          check_image!(image_bytes, mime)

          message = @client.beta.messages.create(
            model: model,
            max_tokens: [ max_tokens, MIN_MAX_TOKENS ].max,
            messages: [ {
              role: "user",
              content: [
                { type: "image", source: { type: "base64", media_type: mime, data: Base64.strict_encode64(image_bytes) } },
                { type: "text", text: prompt }
              ]
            } ],
            output_config: { effort: :low, format: { type: :json_schema, schema: schema } },
            fallbacks: :default,
            betas: [ FALLBACK_BETA ]
          )

          case message.stop_reason
          when :refusal
            raise RefusalError, "#{self.class}: model declined (#{message.stop_details&.category || 'no category'})"
          when :max_tokens
            raise InvalidResponseError, "#{self.class}: response cut off at max_tokens"
          end

          text = message.content.select { |block| block.type == :text }.map(&:text).join
          Result.new(
            data: parse_json!(text),
            input_tokens: message.usage.input_tokens,
            output_tokens: message.usage.output_tokens,
            model: message.model.to_s
          )
        end

        def retryable?(error)
          case error
          when ::Anthropic::Errors::RateLimitError,
               ::Anthropic::Errors::InternalServerError, # includes 529 overloaded
               ::Anthropic::Errors::APIConnectionError   # includes timeouts
            true
          else
            false
          end
        end

        def check_image!(image_bytes, mime)
          unless SUPPORTED_MIME_TYPES.include?(mime)
            raise UnsupportedInputError, "#{self.class}: unsupported image type #{mime} (supported: #{SUPPORTED_MIME_TYPES.join(', ')})"
          end
          return if image_bytes.bytesize <= MAX_IMAGE_BYTES

          raise UnsupportedInputError, "#{self.class}: image is #{image_bytes.bytesize} bytes; the limit is #{MAX_IMAGE_BYTES}"
        end
      end
    end
  end
end
