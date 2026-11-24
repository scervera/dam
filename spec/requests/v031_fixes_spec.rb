require "rails_helper"

RSpec.describe "0.3.1 fixes" do
  let(:tenant) { create_tenant }
  let(:admin) { create_user(tenant, role: "admin") }
  let(:writer) { create_user(tenant, role: "writer") }

  describe "watched folders" do
    let(:params) do
      { watched_folder: { name: "Inbox", path: Dir.tmpdir, scan_frequency_value: 5, scan_frequency_unit: "minutes",
                          max_file_size_bytes: 10.megabytes } }
    end

    it "creates folders in the current tenant" do
      post "/api/v1/watched_folders", params: params, headers: auth(admin)

      expect(response).to have_http_status(:created), response.body
      expect(Dam::WatchedFolder.sole.tenant).to eq(tenant)
    end

    it "is for owners and admins only" do
      post "/api/v1/watched_folders", params: params, headers: auth(writer)
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/watched_folders", headers: auth(writer)
      expect(response).to have_http_status(:forbidden)
    end

    it "keeps paths inside watched_folder_roots when set" do
      root = Dir.mktmpdir
      allow(Dam.config).to receive(:watched_folder_roots).and_return([ root ])

      post "/api/v1/watched_folders", params: params.deep_merge(watched_folder: { path: "#{root}/../" }), headers: auth(admin)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].join).to include("must be inside")

      FileUtils.mkdir_p("#{root}/photos")
      post "/api/v1/watched_folders", params: params.deep_merge(watched_folder: { path: "#{root}/photos" }), headers: auth(admin)
      expect(response).to have_http_status(:created)
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "returns scan history as a list" do
      folder = Dam::WatchedFolder.create!(params[:watched_folder].merge(tenant: tenant))
      folder.folder_scans.create!(tenant: tenant, started_at: 1.minute.ago, status: "completed", files_found: 2, files_processed: 2)

      get "/api/v1/watched_folders/#{folder.id}/scan_history", headers: auth(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to contain_exactly(include("files_found" => 2))
    end
  end

  it "shows drop zone files without host routes" do
    zone = Dam::DropZone.create!(name: "Event", owner: writer, tenant: tenant)
    asset = create_asset(writer)
    Dam::DropZoneFile.create!(drop_zone: zone, asset: asset, uploaded_by: writer, uploaded_at: Time.current)

    get "/api/v1/drop_zones/#{zone.id}", headers: auth(writer)

    expect(response).to have_http_status(:ok), response.body
    file = response.parsed_body["recent_files"].first["asset"]
    expect(file["download_url"]).to end_with("/api/v1/assets/#{asset.id}/stream")
  end

  it "lets writers delete tags on their own assets" do
    asset = create_asset(writer)
    tag = Dam::Tag.create!(name: "mine", tenant: tenant)
    asset.tags << tag

    delete "/api/v1/tags/#{tag.id}", headers: auth(writer)

    expect(response).to have_http_status(:ok), response.body
    expect(Dam::Tag.exists?(tag.id)).to be(false)
  end
end

RSpec.describe "asset list cache" do
  let(:tenant) { create_tenant }
  let(:writer) { create_user(tenant, role: "writer") }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  it "shows a new upload right after the list was cached" do
    get "/api/v1/assets", headers: auth(writer)
    expect(response.parsed_body["data"]).to be_empty

    create_asset(writer)

    get "/api/v1/assets", headers: auth(writer)
    expect(response.parsed_body["data"].size).to eq(1)
  end
end
