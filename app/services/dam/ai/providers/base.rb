# frozen_string_literal: true

module Dam
  module Ai
    module Providers
      # The interface every AI provider implements, plus the retry, request-wrapper and
      # usage-event handling they share. Subclasses implement #request and #retryable?.
      #
      # A host can pass its own adapter as Dam.config.ai_provider: any object with
      # #analyze_image returning a Result works, subclassing Base is optional.
      class Base
        MAX_RETRIES = 3
        INITIAL_RETRY_DELAY = 2 # seconds

        Result = Struct.new(:data, :input_tokens, :output_tokens, :model, keyword_init: true)

        class Error < StandardError; end
        # The model declined the request. Retrying the same input won't help.
        class RefusalError < Error; end
        # The response could not be used (empty, cut off, or not the requested JSON).
        class InvalidResponseError < Error; end
        # The provider can't accept this input (e.g. image type or size).
        class UnsupportedInputError < Error; end

        attr_reader :name, :model

        # sleeper: how to wait between retries (replaced in tests).
        def initialize(name:, model:, api_key: nil, base_url: nil, sleeper: ->(seconds) { sleep(seconds) })
          @name = name.to_sym
          @model = model
          @api_key = api_key
          @base_url = base_url
          @sleeper = sleeper
        end

        # Sends one image with a prompt and returns a Result whose data is the Hash the
        # model returned, matching `schema` (a JSON Schema object). Raises Error subclasses
        # for unusable responses, and the SDK's error after the last failed retry.
        def analyze_image(prompt:, image_bytes:, mime:, schema:, max_tokens: 1024)
          result = with_retries do
            request(prompt: prompt, image_bytes: image_bytes, mime: mime, schema: schema, max_tokens: max_tokens)
          end
          publish_usage(result)
          result
        end

        private

        def request(prompt:, image_bytes:, mime:, schema:, max_tokens:)
          raise NotImplementedError, "#{self.class} must implement #request"
        end

        # Whether an error from the provider's SDK is transient (rate limit, server error,
        # network). Checked before each retry.
        def retryable?(_error)
          false
        end

        def with_retries(&block)
          attempt = 0
          begin
            Dam.config.ai_request_wrapper.call(&block)
          rescue StandardError => e
            raise if attempt >= MAX_RETRIES

            if host_retryable?(e)
              # The host's request wrapper says it's transient (e.g. its own rate limiter):
              # a short jittered wait.
              @sleeper.call(1 + (rand * 2.0))
            elsif retryable?(e)
              delay = INITIAL_RETRY_DELAY * (2**attempt)
              Rails.logger.warn "#{self.class}: #{e.class}: #{e.message} (attempt #{attempt + 1}/#{MAX_RETRIES + 1}); retrying in #{delay}s"
              @sleeper.call(delay)
            else
              raise
            end
            attempt += 1
            retry
          end
        end

        def host_retryable?(error)
          Array(Dam.config.ai_retryable_errors).any? do |klass|
            klass = klass.to_s.safe_constantize unless klass.is_a?(Module)
            klass && error.is_a?(klass)
          end
        end

        def publish_usage(result)
          tenant = Dam.current_tenant
          return unless tenant

          Dam.instrument("ai_usage", tenant: tenant,
                                     input_tokens: result.input_tokens.to_i,
                                     output_tokens: result.output_tokens.to_i,
                                     provider: name,
                                     model: result.model || model)
        end

        def parse_json!(text)
          raise InvalidResponseError, "#{self.class}: empty response" if text.blank?

          data = JSON.parse(text)
          raise InvalidResponseError, "#{self.class}: expected a JSON object" unless data.is_a?(Hash)

          data
        rescue JSON::ParserError => e
          raise InvalidResponseError, "#{self.class}: response is not valid JSON (#{e.message})"
        end

        # Requires a provider SDK that the host may not have installed.
        def require_sdk(feature, gem_name)
          require feature
        rescue LoadError
          raise Providers::ConfigurationError,
                "The #{name} AI provider needs the #{gem_name.inspect} gem. Add it to your Gemfile."
        end
      end
    end
  end
end
