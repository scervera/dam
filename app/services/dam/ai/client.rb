# frozen_string_literal: true

require "openai"

module Dam
  module Ai
    class Client
      MAX_RETRIES = 3
      INITIAL_RETRY_DELAY = 2 # seconds

      def initialize
        @client = OpenAI::Client.new(
          access_token: api_key,
          request_timeout: 120
        )
      end

      # Supports both text-only and vision (image) messages.
      # For vision, messages may have content as array of parts, e.g.:
      #   [{ role: "user", content: [{ type: "text", text: "..." }, { type: "image_url", image_url: { url: "data:image/jpeg;base64,..." } }] }]
      def chat_completion(messages:, model: vision_model, temperature: default_temperature, max_tokens: nil)
        (MAX_RETRIES + 1).times do |attempt|
          begin
            parameters = {
              model: model,
              messages: messages,
              temperature: temperature,
              response_format: { type: "json_object" }
            }
            parameters[:max_tokens] = max_tokens if max_tokens

            Rails.logger.info "Dam::Ai::Client: Vision/tagging request (attempt #{attempt + 1}/#{MAX_RETRIES + 1}), model=#{model}"
            start_time = Time.current
            response = Dam.config.ai_request_wrapper.call { @client.chat(parameters: parameters) }
            duration = Time.current - start_time
            Rails.logger.info "Dam::Ai::Client: Completed in #{duration.round(2)}s"

            usage = extract_usage(response)
            if usage && Dam.current_tenant
              Dam.instrument("ai_usage", tenant: Dam.current_tenant,
                                         input_tokens: usage[:prompt_tokens].to_i,
                                         output_tokens: usage[:completion_tokens].to_i)
            end

            return response
          rescue OpenAI::Error => e
            if retryable_error?(e) && attempt < MAX_RETRIES
              delay = INITIAL_RETRY_DELAY * (2**attempt)
              Rails.logger.warn "Dam::Ai::Client: OpenAI error (attempt #{attempt + 1}/#{MAX_RETRIES}): #{e.message}. Retrying in #{delay}s..."
              sleep(delay)
              next
            end
            raise
          rescue StandardError => e
            # Errors the host's ai_request_wrapper marks as transient (e.g. a rate-limit
            # admission timeout): short jittered wait, then retry.
            if host_retryable_error?(e) && attempt < MAX_RETRIES
              sleep(1 + (rand * 2.0))
              next
            end
            if retryable_http_error?(e) && attempt < MAX_RETRIES
              delay = INITIAL_RETRY_DELAY * (2**attempt)
              Rails.logger.warn "Dam::Ai::Client: HTTP error (attempt #{attempt + 1}/#{MAX_RETRIES}): #{e.message}. Retrying in #{delay}s..."
              sleep(delay)
              next
            end
            raise
          end
        end

        raise "Dam::Ai::Client: chat completion failed after #{MAX_RETRIES} retries"
      end

      private

      def host_retryable_error?(error)
        Array(Dam.config.ai_retryable_errors).any? do |klass|
          klass = klass.to_s.safe_constantize unless klass.is_a?(Module)
          klass && error.is_a?(klass)
        end
      end

      def extract_usage(response)
        return nil if response.nil?
        usage = response["usage"] if response.respond_to?(:[])
        usage ||= response[:usage] if response.respond_to?(:[])
        usage ||= response.usage if response.respond_to?(:usage)
        return nil if usage.nil?
        pt = usage["prompt_tokens"] || usage[:prompt_tokens]
        ct = usage["completion_tokens"] || usage[:completion_tokens]
        tt = usage["total_tokens"] || usage[:total_tokens]
        return nil if pt.nil? && ct.nil?
        { prompt_tokens: pt, completion_tokens: ct, total_tokens: tt }
      end

      def retryable_error?(error)
        return true if openai_rate_limit_error?(error)
        return true if openai_internal_server_error?(error)
        return true if error.message.to_s.match?(/status\s+(?:50[0-9]|52[0-9]|53[0-9])/)
        return true if error.message.to_s.match?(/server\s+error/i)
        return true if error.message.to_s.match?(/timeout/i)
        false
      end

      def retryable_http_error?(error)
        return true if error.message.to_s.match?(/status\s+(?:50[0-9]|52[0-9]|53[0-9])/)
        return true if error.message.to_s.match?(/520|502|503|504/)
        return true if error.message.to_s.match?(/timeout|connection/i)
        if error.respond_to?(:response) && error.response.is_a?(Hash)
          status = error.response[:status] || error.response["status"]
          return true if status.to_i >= 500 && status.to_i < 600
        end
        false
      end

      def openai_rate_limit_error?(error)
        %w[
          OpenAI::RateLimitError
          OpenAI::TooManyRequestsError
          OpenAI::Errors::RateLimitError
          OpenAI::Errors::TooManyRequestsError
        ].include?(error.class.name)
      end

      def openai_internal_server_error?(error)
        %w[
          OpenAI::InternalServerError
          OpenAI::Errors::InternalServerError
        ].include?(error.class.name)
      end

      def api_key
        ENV["OPENAI_API_KEY"] || raise("OPENAI_API_KEY environment variable is not set")
      end

      def vision_model
        ENV.fetch("OPENAI_VISION_MODEL", "gpt-4o")
      end

      def default_temperature
        ENV.fetch("OPENAI_TEMPERATURE", "0.3").to_f
      end
    end
  end
end
