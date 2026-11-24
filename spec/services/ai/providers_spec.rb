require "rails_helper"

RSpec.describe Dam::Ai::Providers, :ai_env do
  it "is not configured without settings" do
    expect(described_class).not_to be_configured
    expect(described_class.current).to be_nil
    expect(Dam).not_to be_ai_tagging_enabled
  end

  it "keeps the pre-0.3 behavior: OPENAI_API_KEY alone selects OpenAI" do
    with_ai_env("OPENAI_API_KEY" => "sk-1", "OPENAI_VISION_MODEL" => "gpt-4.1") do
      provider = described_class.current
      expect(provider).to be_a(Dam::Ai::Providers::OpenAi)
      expect(provider.name).to eq(:openai)
      expect(provider.model).to eq("gpt-4.1")
      expect(Dam).to be_ai_tagging_enabled
    end
  end

  it "selects Anthropic with its default model and ANTHROPIC_API_KEY" do
    with_ai_env("DAM_AI_PROVIDER" => "anthropic", "ANTHROPIC_API_KEY" => "sk-ant") do
      provider = described_class.current
      expect(provider).to be_a(Dam::Ai::Providers::Anthropic)
      expect(provider.model).to eq("claude-opus-5-5")
    end
  end

  it "prefers the DAM_AI_* settings" do
    with_ai_env("DAM_AI_PROVIDER" => "anthropic", "DAM_AI_API_KEY" => "k", "DAM_AI_MODEL" => "claude-haiku-5-5") do
      expect(described_class.current.model).to eq("claude-haiku-5-5")
    end
  end

  it "needs a base URL and model for an OpenAI-compatible server, but no key" do
    with_ai_env("DAM_AI_PROVIDER" => "openai_compatible", "DAM_AI_BASE_URL" => "http://ollama:11434/v1") do
      expect(described_class).not_to be_configured
    end
    with_ai_env("DAM_AI_PROVIDER" => "openai_compatible", "DAM_AI_BASE_URL" => "http://ollama:11434/v1",
                "DAM_AI_MODEL" => "llava") do
      expect(described_class.current).to have_attributes(name: :openai_compatible, model: "llava")
    end
  end

  it "is not configured when the provider has no key" do
    with_ai_env("DAM_AI_PROVIDER" => "anthropic") do
      expect(described_class).not_to be_configured
    end
  end

  it "rejects an unknown provider name" do
    expect { described_class.build(:mystery) }.to raise_error(described_class::ConfigurationError, /mystery/)
  end

  it "uses an adapter object set in Dam.config.ai_provider" do
    adapter = Object.new
    def adapter.analyze_image(**) = nil
    allow(Dam.config).to receive(:ai_provider).and_return(adapter)

    expect(described_class.current).to be(adapter)
    expect(described_class).to be_configured
  end

  it "can be switched off with DAM_AI_AUTO_TAG_ENABLED" do
    with_ai_env("OPENAI_API_KEY" => "sk-1", "DAM_AI_AUTO_TAG_ENABLED" => "false") do
      expect(Dam).not_to be_ai_tagging_enabled
    end
  end
end
