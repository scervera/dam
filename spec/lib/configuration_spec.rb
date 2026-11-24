require "rails_helper"

RSpec.describe Dam::Configuration do
  subject(:config) { described_class.new }

  it "defaults to a standalone setup" do
    expect(config.tenant_class).to eq("Tenant")
    expect(config.user_class).to eq("User")
    expect(config.parent_controller).to eq("ActionController::API")
    expect(config.soft_delete_enabled.call).to be(false)
    expect(config.asset_retention_days.call).to eq(30)
    expect(config.storage_service_for.call("derivative")).to be_nil
    expect(config.authenticate_token.call("anything")).to be_nil
  end

  it "keeps the current tenant and user in Dam::Current by default" do
    tenant = create_tenant
    config.set_current_tenant.call(tenant)
    expect(config.current_tenant.call).to eq(tenant)
    expect(Dam::Current.tenant).to eq(tenant)
  end

  it "wraps AI requests transparently by default" do
    expect(config.ai_request_wrapper.call { :response }).to eq(:response)
  end

  it "resolves the host's model classes" do
    expect(Dam.tenant_class).to eq(Tenant)
    expect(Dam.user_class).to eq(User)
    expect(Dam::Asset.reflect_on_association(:user).klass).to eq(User)
  end

  it "uses the default queue for every job kind unless the host overrides some" do
    expect(config.queue_names.values.uniq).to eq([ :default ])

    config.queue_names = { "purge" => :low_priority }

    expect(config.queue_name(:purge)).to eq(:low_priority)
    expect(config.queue_name(:ai)).to eq(:default)
  end

  it "routes each job to its configured queue" do
    allow(Dam.config).to receive(:queue_names).and_return(
      Dam::Configuration::DEFAULT_QUEUE_NAMES.merge(purge: :purges, ai: :ai_jobs)
    )

    expect(Dam::PurgeAssetJob.new.queue_name).to eq("purges")
    expect(Dam::Ai::AutoTaggingJob.new.queue_name).to eq("ai_jobs")
    expect(Dam::AssetThumbnailJob.new.queue_name).to eq("default")
  end
end
