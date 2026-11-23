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
end
