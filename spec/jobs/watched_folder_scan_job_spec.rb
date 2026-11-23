require "rails_helper"

RSpec.describe Dam::WatchedFolderScanJob do
  it "imports files and attributes them to Dam.config.import_user_for" do
    tenant = create_tenant
    importer = create_user(tenant, role: "owner")
    create_user(tenant)
    allow(Dam.config).to receive(:import_user_for).and_return(->(t) { t.users.find_by(role: "owner") })

    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "scan.png"), DamSpecHelpers::PNG)
      folder = Dam::WatchedFolder.create!(tenant: tenant, name: "Inbox", path: dir, active: true,
                                          scan_frequency_value: 5, scan_frequency_unit: "minutes",
                                          max_file_size_bytes: 10.megabytes)

      described_class.perform_now(folder.id)

      asset = Dam::Asset.find_by!(name: "scan.png")
      expect(asset.user).to eq(importer)
      expect(asset.tenant).to eq(tenant)
      expect(asset).to be_auto_imported
      expect(File.exist?(File.join(dir, "scan.png"))).to be(false) # moved into storage
    end
  end
end
