# frozen_string_literal: true

module Dam
  module Ai
    # Picks the AI provider that auto-tagging uses.
    #
    # Dam.config.ai_provider can be an adapter object (anything implementing
    # Base#analyze_image) or a provider name. When it is nil, the provider comes from ENV:
    #
    #   DAM_AI_PROVIDER   openai | openai_compatible | anthropic. When unset, "openai" is
    #                     assumed if OPENAI_API_KEY is set (the pre-0.3 behavior).
    #   DAM_AI_MODEL      model name. Defaults: openai "gpt-4o" (or OPENAI_VISION_MODEL),
    #                     anthropic "claude-opus-5-5"; openai_compatible requires it.
    #   DAM_AI_API_KEY    API key. Falls back to OPENAI_API_KEY or ANTHROPIC_API_KEY.
    #                     Optional for openai_compatible (e.g. a local Ollama).
    #   DAM_AI_BASE_URL   API base URL. Required for openai_compatible, e.g.
    #                     http://ollama:11434/v1; optional for the others (proxies).
    module Providers
      ADAPTERS = {
        openai: "Dam::Ai::Providers::OpenAi",
        openai_compatible: "Dam::Ai::Providers::OpenAi",
        anthropic: "Dam::Ai::Providers::Anthropic"
      }.freeze

      DEFAULT_MODELS = {
        openai: "gpt-4o",
        anthropic: "claude-opus-5-5"
      }.freeze

      class ConfigurationError < StandardError; end

      class << self
        # The adapter to use, or nil when none is configured.
        def current
          configured = Dam.config.ai_provider
          return configured if adapter_object?(configured)

          build(configured || name_from_env) if configured?
        end

        def configured?(env = ENV)
          configured = Dam.config.ai_provider
          return true if adapter_object?(configured)

          name = configured || name_from_env(env)
          return false if name.nil?

          settings = settings_for(name, env)
          case name.to_sym
          when :openai, :anthropic then settings[:api_key].present?
          when :openai_compatible then settings[:base_url].present? && settings[:model].present?
          else false
          end
        end

        # The configured provider's name (:openai, :anthropic, ...), or nil.
        def current_name(env = ENV)
          configured = Dam.config.ai_provider
          return configured.name if adapter_object?(configured) && configured.respond_to?(:name)

          (configured || name_from_env(env))&.to_sym
        end

        def build(name, env = ENV)
          name = name.to_sym
          class_name = ADAPTERS[name] or
            raise ConfigurationError, "Unknown AI provider #{name.inspect} (expected one of #{ADAPTERS.keys.join(', ')})"

          class_name.constantize.new(name: name, **settings_for(name, env))
        end

        private

        def adapter_object?(value)
          value.respond_to?(:analyze_image)
        end

        def name_from_env(env = ENV)
          explicit = env["DAM_AI_PROVIDER"].presence
          return explicit.to_s.downcase.to_sym if explicit

          :openai if env["OPENAI_API_KEY"].present?
        end

        def settings_for(name, env)
          name = name.to_sym
          {
            model: env["DAM_AI_MODEL"].presence || default_model(name, env),
            api_key: env["DAM_AI_API_KEY"].presence || provider_api_key(name, env),
            base_url: env["DAM_AI_BASE_URL"].presence
          }
        end

        def default_model(name, env)
          return env["OPENAI_VISION_MODEL"].presence || DEFAULT_MODELS[:openai] if name == :openai

          DEFAULT_MODELS[name]
        end

        def provider_api_key(name, env)
          case name
          when :openai, :openai_compatible then env["OPENAI_API_KEY"].presence
          when :anthropic then env["ANTHROPIC_API_KEY"].presence
          end
        end
      end
    end
  end
end
