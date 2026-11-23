require "rails_helper"

RSpec.describe "DAM serializers" do
  let(:user) { create_user(create_tenant) }

  it "serializes assets flat, with the default user/tenant representations" do
    asset = create_asset(user)
    asset.add_tag("sermon")

    hash = Dam::AssetSerializer.flat(asset.reload)

    expect(hash).to include(id: asset.id, name: "photo.png", file_type: "image/png", is_derivative: false)
    expect(hash[:user]).to eq(id: user.id)
    expect(hash[:tenant]).to eq(id: user.tenant.id)
    expect(hash[:tags].map { _1[:name] }).to eq([ "sermon" ])
    expect(Dam::AssetSerializer.flat(asset, params: { associations: false })).not_to include(:user, :tenant, :tags)
  end

  it "serializes collections of records" do
    tags = [ Dam::Tag.create!(name: "a1", tenant: user.tenant), Dam::Tag.create!(name: "b2", tenant: user.tenant) ]

    expect(Dam::TagSerializer.flat(tags).map { _1[:name] }).to eq(%w[a1 b2])
  end
end
