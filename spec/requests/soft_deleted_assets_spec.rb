require "rails_helper"

RSpec.describe "soft-deleted assets" do
  let(:tenant) { create_tenant }
  let(:owner) { create_user(tenant, role: "writer") }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  before { allow(Dam.config).to receive(:soft_delete_enabled).and_return(-> { true }) }

  def ids(body = response.parsed_body)
    body["data"].map { |a| a["id"].to_s }
  end

  %w[admin owner writer].each do |role|
    context "as #{role}" do
      let(:user) { create_user(tenant, role: role) }
      let!(:kept) { create_asset(owner, name: "kept.png") }
      let!(:gone) { create_asset(owner, name: "gone.png") }

      before do
        # Prime the list cache so a stale page would mask the fix.
        get "/api/v1/assets", headers: auth(user)
        expect(response.parsed_body["meta"]["total_count"]).to eq(2)

        delete "/api/v1/assets/#{gone.id}", headers: auth(role == "writer" ? owner : user)
        expect(response).to have_http_status(:ok), response.body
        expect(gone.reload.deleted_at).to be_present
      end

      it "leaves them out of index and search" do
        get "/api/v1/assets", headers: auth(user)
        expect(ids).to eq([ kept.id.to_s ])
        expect(response.parsed_body["meta"]["total_count"]).to eq(1)

        get "/api/v1/assets", params: { q: "gone" }, headers: auth(user)
        expect(ids).to be_empty

        get "/api/v1/assets/search", params: { q: "gone" }, headers: auth(user)
        expect(ids).to be_empty
      end

      it "returns 404 from show" do
        get "/api/v1/assets/#{gone.id}", headers: auth(user)
        expect(response).to have_http_status(:not_found)
      end

      it "leaves them out of smart folders, tags and collections" do
        tag = Dam::Tag.create!(name: "trip", tenant: tenant)
        [ kept, gone ].each { |a| Dam::AssetTag.create!(asset: a, tag: tag, tenant: tenant) }
        folder = Dam::SmartFolder.create!(name: "Trip", tag_criteria: "trip", user: user, tenant: tenant,
                                          visibility_level: "global", match_logic: "any", sort_order: 0)
        collection = Dam::Collection.create!(name: "C", user: user, tenant: tenant, is_public: false)
        [ kept, gone ].each { |a| Dam::CollectionAsset.create!(collection: collection, asset: a, tenant: tenant) }

        get "/api/v1/smart_folders/#{folder.id}/assets", headers: auth(user)
        expect(ids).to eq([ kept.id.to_s ])
        expect(folder.asset_count(user)).to eq(1)

        get "/api/v1/tags/trip", headers: auth(user)
        expect(response.parsed_body["assets"].map { |a| a["id"].to_s }).to eq([ kept.id.to_s ])
        expect(tag.asset_count).to eq(1)

        get "/api/v1/collections/#{collection.id}", headers: auth(user)
        attrs = response.parsed_body["data"]["attributes"]
        expect(attrs["asset_count"]).to eq(1)
        expect(attrs["asset_ids"]).to eq([ kept.id ])
      end

      it "leaves them out of drop zone files" do
        zone = Dam::DropZone.create!(name: "Event", owner: user, tenant: tenant)
        [ kept, gone ].each do |a|
          Dam::DropZoneFile.create!(drop_zone: zone, asset: a, uploaded_by: owner, uploaded_at: Time.current)
        end

        get "/api/v1/drop_zones/#{zone.id}/files", headers: auth(user)
        expect(response.parsed_body["files"].map { |f| f["asset"]["id"] }).to eq([ kept.id ])
        expect(response.parsed_body["meta"]["total"]).to eq(1)
      end

      it "keeps them in the recycle bin, and restore brings them back" do
        actor = role == "writer" ? owner : user

        get "/api/v1/assets/recycle_bin", headers: auth(actor)
        expect(ids).to eq([ gone.id.to_s ])

        post "/api/v1/assets/#{gone.id}/restore", headers: auth(actor)
        expect(response).to have_http_status(:ok), response.body

        get "/api/v1/assets", headers: auth(user)
        expect(ids).to contain_exactly(kept.id.to_s, gone.id.to_s)
        expect(response.parsed_body["meta"]["total_count"]).to eq(2)
      end

      it "can purge them" do
        actor = role == "writer" ? owner : user
        gone.update!(purge_after: 1.minute.ago) # writers must wait out retention

        delete "/api/v1/assets/#{gone.id}/purge", headers: auth(actor)
        expect(response).to have_http_status(:ok), response.body
      end
    end
  end
end
