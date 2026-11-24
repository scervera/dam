require "webmock/rspec"

module AiHelpers
  AI_ENV_KEYS = %w[
    DAM_AI_PROVIDER DAM_AI_MODEL DAM_AI_API_KEY DAM_AI_BASE_URL DAM_AI_AUTO_TAG_ENABLED
    OPENAI_API_KEY OPENAI_VISION_MODEL ANTHROPIC_API_KEY DAM_FACE_DETECTION_ENABLED
  ].freeze

  # Runs the block with only the given AI-related ENV values set (others cleared).
  def with_ai_env(values = {})
    saved = AI_ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
    AI_ENV_KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key.to_s] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

RSpec.configure do |config|
  config.include AiHelpers
  config.around(:each, :ai_env) { |example| with_ai_env { example.run } }
end
