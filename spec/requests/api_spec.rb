require "rails_helper"

RSpec.describe "DAM API in a minimal host app" do
  let(:tenant) { create_tenant }
  let(:user) { create_user(tenant, role: "admin") }

  it "requires authentication" do
    get "/api/v1/assets"
    expect(response).to have_http_status(:unauthorized)
  end

  it "lists only the current tenant's assets" do
    mine = create_asset(user, name: "mine.png")
    create_asset(create_user(create_tenant("Other")), name: "theirs.png")

    get "/api/v1/assets", headers: auth(user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].map { _1["id"] }).to eq([ mine.id.to_s ])
  end

  it "uploads an asset with tags" do
    file = Rack::Test::UploadedFile.new(StringIO.new(DamSpecHelpers::PNG), "image/png", original_filename: "up.png")

    post "/api/v1/assets", params: { asset: { name: "up.png", file: file, tag_names: %w[sermon] } }, headers: auth(user)

    expect(response).to have_http_status(:created)
    expect(Dam::Asset.last.tag_names).to eq([ "sermon" ])
  end

  it "shows an asset in the flat representation" do
    asset = create_asset(user)

    get "/api/v1/assets/#{asset.id}", headers: auth(user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => asset.id, "name" => "photo.png", "file_type" => "image/png")
    expect(response.parsed_body["user"]).to eq("id" => user.id)
  end

  it "creates and lists tags" do
    post "/api/v1/tags", params: { tag: { name: "easter" } }, headers: auth(user)
    expect(response).to have_http_status(:created)

    get "/api/v1/tags", headers: auth(user)
    expect(response.parsed_body.to_s).to include("easter")
  end

  it "manages groups with the default find_tenant_user (tenant.users)" do
    member = create_user(tenant)

    post "/api/v1/groups", params: { group: { name: "Media" } }, headers: auth(user)
    group_id = response.parsed_body.dig("data", "id")
    post "/api/v1/groups/#{group_id}/add_member", params: { user_id: member.id }, headers: auth(user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["included"].map { _1.dig("attributes", "email") }).to eq([ member.email ])
  end

  it "creates collections" do
    post "/api/v1/collections", params: { collection: { name: "Covers", is_public: false } }, headers: auth(user)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "attributes", "name")).to eq("Covers")
  end

  it "forbids viewers from uploading" do
    viewer = create_user(tenant, role: "viewer")

    post "/api/v1/assets", params: { asset: { name: "x.png" } }, headers: auth(viewer)

    expect(response).to have_http_status(:forbidden)
  end

  describe "stream" do
    it "requires a token and serves the file with one" do
      asset = create_asset(user)

      get "/api/v1/assets/#{asset.id}/stream"
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/assets/#{asset.id}/stream", params: { token: user.api_token }
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(DamSpecHelpers::PNG.b)
    end

    it "does not serve another tenant's asset" do
      foreign = create_asset(create_user(create_tenant("Other")))

      get "/api/v1/assets/#{foreign.id}/stream", params: { token: user.api_token }

      expect(response).to have_http_status(:not_found)
    end
  end
end
