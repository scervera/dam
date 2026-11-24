require "rails_helper"

# Every adapter must behave the same way behind Base#analyze_image.
RSpec.shared_examples "an AI provider adapter" do
  let(:schema) { Dam::Ai::AutoTaggingService::TAG_SCHEMA }
  let(:call_args) do
    { prompt: "Tag this image.", image_bytes: DamSpecHelpers::PNG, mime: "image/png", schema: schema, max_tokens: 512 }
  end

  it "sends the image and returns the parsed JSON with token usage" do
    stub_success({ "existing_tags" => [ "beach" ], "new_tags" => [ "sunset" ] }, input_tokens: 120, output_tokens: 30)

    result = adapter.analyze_image(**call_args)

    expect(result.data).to eq("existing_tags" => [ "beach" ], "new_tags" => [ "sunset" ])
    expect(result.input_tokens).to eq(120)
    expect(result.output_tokens).to eq(30)
    expect(result.model).to be_present
    expect(last_request_body).to include(Base64.strict_encode64(DamSpecHelpers::PNG))
  end

  it "retries rate limits and server errors with backoff, then succeeds" do
    stub_statuses(429, 500)

    result = adapter.analyze_image(**call_args)

    expect(result.data).to include("new_tags")
    expect(sleeps).to eq([ 2, 4 ])
  end

  it "gives up after the last retry" do
    stub_statuses(500, 500, 500, 500)

    expect { adapter.analyze_image(**call_args) }.to raise_error(StandardError)
    expect(sleeps.size).to eq(Dam::Ai::Providers::Base::MAX_RETRIES)
  end

  it "does not retry client errors" do
    stub_statuses(400)

    expect { adapter.analyze_image(**call_args) }.to raise_error(StandardError)
    expect(sleeps).to be_empty
  end

  it "rejects a reply that is not JSON" do
    stub_text_reply("Sure! Here are some tags: beach, sunset")

    expect { adapter.analyze_image(**call_args) }
      .to raise_error(Dam::Ai::Providers::Base::InvalidResponseError)
  end

  it "runs requests through the host's ai_request_wrapper and publishes usage" do
    stub_success({ "existing_tags" => [], "new_tags" => [ "dog" ] }, input_tokens: 10, output_tokens: 5)
    wrapped = 0
    allow(Dam.config).to receive(:ai_request_wrapper).and_return(->(&request) { wrapped += 1; request.call })
    tenant = create_tenant
    Dam.current_tenant = tenant
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("ai_usage.dam") { |event| events << event.payload }

    adapter.analyze_image(**call_args)

    expect(wrapped).to eq(1)
    expect(events).to contain_exactly(
      include(tenant: tenant, input_tokens: 10, output_tokens: 5, provider: adapter.name, model: be_present)
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "retries errors the host marks as retryable" do
    stub_success({ "existing_tags" => [], "new_tags" => [ "cat" ] }, input_tokens: 1, output_tokens: 1)
    stub_const("HostThrottled", Class.new(StandardError))
    calls = 0
    allow(Dam.config).to receive(:ai_request_wrapper).and_return(lambda do |&request|
      calls += 1
      raise HostThrottled if calls == 1

      request.call
    end)
    allow(Dam.config).to receive(:ai_retryable_errors).and_return([ "HostThrottled" ])

    expect(adapter.analyze_image(**call_args).data["new_tags"]).to eq([ "cat" ])
    expect(sleeps.size).to eq(1)
  end
end

RSpec.describe "AI provider adapters" do
  let(:sleeps) { [] }

  def last_request_body = @last_body.to_s

  shared_context "an OpenAI Chat Completions endpoint" do
    def chat_response(content)
      {
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-1", object: "chat.completion", model: adapter.model,
          choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: content } } ],
          usage: { prompt_tokens: @input_tokens || 1, completion_tokens: @output_tokens || 1 }
        }.to_json
      }
    end

    def stub_success(data, input_tokens:, output_tokens:)
      @input_tokens = input_tokens
      @output_tokens = output_tokens
      stub_text_reply(data.to_json)
    end

    def stub_text_reply(text)
      stub_request(:post, endpoint).to_return { |request| @last_body = request.body; chat_response(text) }
    end

    def stub_statuses(*statuses)
      responses = statuses.map { |status| { status: status, body: { error: { message: "HTTP #{status}" } }.to_json } }
      stub_request(:post, endpoint).to_return(*responses, chat_response({ "existing_tags" => [], "new_tags" => [ "ok" ] }.to_json))
    end
  end

  describe Dam::Ai::Providers::OpenAi do
    include_context "an OpenAI Chat Completions endpoint"
    let(:endpoint) { "https://api.openai.com/v1/chat/completions" }
    let(:adapter) { described_class.new(name: :openai, model: "gpt-4o", api_key: "sk-test", sleeper: ->(s) { sleeps << s }) }

    it_behaves_like "an AI provider adapter"

    it "asks for JSON mode and sends the API key" do
      stub_success({ "existing_tags" => [], "new_tags" => [] }, input_tokens: 1, output_tokens: 1)
      adapter.analyze_image(prompt: "p", image_bytes: "x", mime: "image/jpeg", schema: {}, max_tokens: 10)

      expect(a_request(:post, endpoint).with(headers: { "Authorization" => "Bearer sk-test" })).to have_been_made
      expect(JSON.parse(@last_body)).to include("model" => "gpt-4o", "response_format" => { "type" => "json_object" })
    end
  end

  describe "Dam::Ai::Providers::OpenAi against an OpenAI-compatible server" do
    include_context "an OpenAI Chat Completions endpoint"
    let(:endpoint) { "http://ollama.test:11434/v1/chat/completions" }
    let(:adapter) do
      Dam::Ai::Providers::OpenAi.new(name: :openai_compatible, model: "llava", base_url: "http://ollama.test:11434/v1",
                                     sleeper: ->(s) { sleeps << s })
    end

    it_behaves_like "an AI provider adapter"
  end

  describe Dam::Ai::Providers::Anthropic do
    let(:endpoint) { %r{\Ahttps://api\.anthropic\.com/v1/messages} }
    let(:adapter) { described_class.new(name: :anthropic, model: "claude-opus-5-5", api_key: "sk-ant-test", sleeper: ->(s) { sleeps << s }) }

    def message_response(text, stop_reason: "end_turn", input_tokens: 1, output_tokens: 1)
      {
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5-5",
          content: [ { type: "text", text: text } ], stop_reason: stop_reason,
          usage: { input_tokens: input_tokens, output_tokens: output_tokens }
        }.to_json
      }
    end

    def stub_success(data, input_tokens:, output_tokens:)
      stub_request(:post, endpoint).to_return do |request|
        @last_body = request.body
        message_response(data.to_json, input_tokens: input_tokens, output_tokens: output_tokens)
      end
    end

    def stub_text_reply(text)
      stub_request(:post, endpoint).to_return { |request| @last_body = request.body; message_response(text) }
    end

    def stub_statuses(*statuses)
      responses = statuses.map do |status|
        { status: status, headers: { "Content-Type" => "application/json" },
          body: { type: "error", error: { type: "api_error", message: "HTTP #{status}" } }.to_json }
      end
      stub_request(:post, endpoint).to_return(*responses, message_response({ "existing_tags" => [], "new_tags" => [ "ok" ] }.to_json))
    end

    it_behaves_like "an AI provider adapter"

    it "uses structured outputs, low effort and server-side fallback" do
      stub_success({ "existing_tags" => [], "new_tags" => [] }, input_tokens: 1, output_tokens: 1)
      adapter.analyze_image(prompt: "p", image_bytes: "x", mime: "image/jpeg", schema: { type: "object" }, max_tokens: 512)

      body = JSON.parse(@last_body)
      expect(body).to include(
        "model" => "claude-opus-5-5",
        "max_tokens" => described_class::MIN_MAX_TOKENS,
        "fallbacks" => "default",
        "output_config" => { "effort" => "low", "format" => { "type" => "json_schema", "schema" => { "type" => "object" } } }
      )
      expect(body.dig("messages", 0, "content", 0)).to include("type" => "image")
      expect(a_request(:post, endpoint).with(headers: { "anthropic-beta" => described_class::FALLBACK_BETA })).to have_been_made
    end

    it "retries an overloaded API" do
      stub_statuses(529)
      expect(adapter.analyze_image(prompt: "p", image_bytes: "x", mime: "image/jpeg", schema: {}).data).to include("new_tags")
      expect(sleeps).to eq([ 2 ])
    end

    it "raises RefusalError when the model declines" do
      stub_request(:post, endpoint).to_return(message_response("", stop_reason: "refusal"))

      expect { adapter.analyze_image(prompt: "p", image_bytes: "x", mime: "image/jpeg", schema: {}) }
        .to raise_error(Dam::Ai::Providers::Base::RefusalError)
    end

    it "rejects image types the API does not accept, without calling it" do
      expect { adapter.analyze_image(prompt: "p", image_bytes: "x", mime: "image/heic", schema: {}) }
        .to raise_error(Dam::Ai::Providers::Base::UnsupportedInputError)
      expect(a_request(:post, endpoint)).not_to have_been_made
    end
  end
end
