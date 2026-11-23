require "rails_helper"

RSpec.describe Dam::Asset do
  let(:tenant) { create_tenant }
  let(:user) { create_user(tenant) }

  it "publishes asset_created.dam after creation" do
    events = []
    callback = ->(event) { events << event.payload[:asset] }
    asset = ActiveSupport::Notifications.subscribed(callback, "asset_created.dam") { create_asset(user) }

    expect(events).to eq([ asset ])
  end

  it "publishes asset_destroying.dam before the row is deleted" do
    asset = create_asset(user)
    still_present = nil
    callback = ->(event) { still_present = Dam::Asset.exists?(event.payload[:asset].id) }

    ActiveSupport::Notifications.subscribed(callback, "asset_destroying.dam") { asset.destroy! }

    expect(still_present).to be(true)
    expect(Dam::Asset.exists?(asset.id)).to be(false)
  end

  it "soft deletes using the configured retention" do
    asset = create_asset(user)
    allow(Dam.config).to receive(:asset_retention_days).and_return(-> { 7 })

    asset.soft_delete!

    expect(asset.deleted_at).to be_present
    expect(asset.purge_after).to be_within(1.minute).of(7.days.from_now)
  end

  it "tags assets, allowing colons (person:Name tags from face recognition)" do
    asset = create_asset(user)

    asset.add_tag("person:Jane")

    expect(asset.reload.tags.map(&:name)).to eq([ "person:Jane" ])
    expect(asset.tags.first.tenant).to eq(tenant)
  end
end
