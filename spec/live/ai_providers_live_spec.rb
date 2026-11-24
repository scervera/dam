require "rails_helper"

# Calls the real provider APIs (costs a few tokens). Skipped unless DAM_LIVE_AI=1; each
# provider also needs its usual settings, e.g.
#   DAM_LIVE_AI=1 ANTHROPIC_API_KEY=... OPENAI_API_KEY=... bundle exec rspec spec/live
#   DAM_LIVE_AI=1 DAM_LIVE_OPENAI_COMPATIBLE_URL=http://localhost:11434/v1 \
#     DAM_LIVE_OPENAI_COMPATIBLE_MODEL=llava bundle exec rspec spec/live
RSpec.describe "AI providers (live)", :live do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
  end

  # A 64x64 red square: big enough for every provider's minimum image size.
  let(:image) do
    Vips::Image.black(64, 64).new_from_image([ 255, 0, 0 ]).cast(:uchar).write_to_buffer(".png")
  end

  def tag(provider)
    provider.analyze_image(
      prompt: "Suggest tags for this image. There are no existing tags.",
      image_bytes: image, mime: "image/png",
      schema: Dam::Ai::AutoTaggingService::TAG_SCHEMA, max_tokens: 512
    )
  end

  {
    anthropic: -> { ENV["ANTHROPIC_API_KEY"] },
    openai: -> { ENV["OPENAI_API_KEY"] }
  }.each do |name, key|
    it "tags an image with #{name}" do
      skip "no API key for #{name}" if key.call.blank?

      provider = Dam::Ai::Providers::OpenAi if name == :openai
      provider ||= Dam::Ai::Providers::Anthropic
      model = ENV["DAM_AI_MODEL"].presence || Dam::Ai::Providers::DEFAULT_MODELS[name]
      result = tag(provider.new(name: name, model: model, api_key: key.call))

      expect(result.data).to include("existing_tags", "new_tags")
      expect(result.input_tokens).to be_positive
    end
  end

  it "tags an image with an OpenAI-compatible server" do
    url = ENV["DAM_LIVE_OPENAI_COMPATIBLE_URL"]
    skip "DAM_LIVE_OPENAI_COMPATIBLE_URL is not set" if url.blank?

    provider = Dam::Ai::Providers::OpenAi.new(name: :openai_compatible, base_url: url,
                                              model: ENV.fetch("DAM_LIVE_OPENAI_COMPATIBLE_MODEL", "llava"))
    expect(tag(provider).data).to include("new_tags")
  end
end
