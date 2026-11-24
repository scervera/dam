require "rails_helper"

RSpec.describe Dam::Ai::AutoTaggingService, :ai_env do
  let(:user) { create_user(create_tenant) }
  let(:fake_provider) do
    Class.new do
      attr_reader :calls
      attr_accessor :reply

      def initialize = @calls = []

      def analyze_image(**args)
        @calls << args
        raise reply if reply.is_a?(Exception)

        Dam::Ai::Providers::Base::Result.new(data: reply, input_tokens: 1, output_tokens: 1, model: "fake")
      end
    end.new
  end

  before { allow(Dam.config).to receive(:ai_provider).and_return(fake_provider) }

  it "applies existing and new tags from the provider's reply" do
    asset = create_asset(user)
    Dam::Tag.create!(name: "beach", tenant: user.tenant)
    fake_provider.reply = { "existing_tags" => [ "beach" ], "new_tags" => [ "Sunset!", "x" ] }

    expect(described_class.new(asset: asset).call).to be(true)

    expect(asset.reload.tags.pluck(:name)).to contain_exactly("beach", "Sunset")
    expect(asset.ai_auto_tagged_at).to be_present
    expect(fake_provider.calls.first).to include(schema: described_class::TAG_SCHEMA, mime: "image/png")
    expect(fake_provider.calls.first[:prompt]).to include("beach")
  end

  it "records a refusal without raising, since retrying won't help" do
    asset = create_asset(user)
    fake_provider.reply = Dam::Ai::Providers::Base::RefusalError.new("declined")

    expect(described_class.new(asset: asset).call).to be(false)
    expect(asset.reload.ai_tagging_error).to eq("declined")
  end

  it "raises other errors so the job can retry" do
    asset = create_asset(user)
    fake_provider.reply = Timeout::Error.new("slow")

    expect { described_class.new(asset: asset).call }.to raise_error(Timeout::Error)
    expect(asset.reload.ai_tagging_error).to eq("slow")
  end

  it "does nothing when no provider is configured" do
    allow(Dam.config).to receive(:ai_provider).and_return(nil)
    asset = create_asset(user)

    expect(described_class.new(asset: asset).call).to be(false)
    expect(fake_provider.calls).to be_empty
  end

  it "only enqueues tagging on upload when a provider is configured" do
    expect { create_asset(user) }.to have_enqueued_job(Dam::Ai::AutoTaggingJob)

    allow(Dam.config).to receive(:ai_provider).and_return(nil)
    expect { create_asset(user, name: "other.png") }.not_to have_enqueued_job(Dam::Ai::AutoTaggingJob)
  end
end
