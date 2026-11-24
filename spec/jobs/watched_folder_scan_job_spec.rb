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

  describe "file handling" do
    let(:tenant) { create_tenant }
    let!(:owner) { create_user(tenant, role: "owner") }

    def scan(dir)
      folder = Dam::WatchedFolder.find_or_create_by!(tenant: tenant, path: dir) do |f|
        f.assign_attributes(name: "Inbox", active: true, scan_frequency_value: 5, scan_frequency_unit: "minutes",
                            max_file_size_bytes: 10.megabytes)
      end
      described_class.perform_now(folder.id)
      folder.folder_scans.order(:id).last
    end

    it "never runs file names as shell commands" do
      Dir.mktmpdir do |dir|
        # A shell would create the marker in the current directory.
        marker = File.join(Dir.pwd, "dam_injection_marker")
        File.binwrite(File.join(dir, "x\"$(touch dam_injection_marker)\".png"), DamSpecHelpers::PNG)

        scan(dir)

        expect(File.exist?(marker)).to be(false)
        expect(Dam::Asset.unscoped.where(tenant: tenant).count).to eq(1)
      ensure
        FileUtils.rm_f(marker) if marker
      end
    end

    it "skips unsupported files and subfolders, counting them as skipped" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "notes.xyz"), "plain text")
        Dir.mkdir(File.join(dir, "sub"))
        File.binwrite(File.join(dir, "photo.png"), DamSpecHelpers::PNG)

        result = scan(dir)

        expect(result).to have_attributes(files_found: 2, files_processed: 1, files_skipped: 1)
        expect(File.exist?(File.join(dir, "notes.xyz"))).to be(true)
      end
    end

    context "with watched_folder_keep_originals" do
      before { allow(Dam.config).to receive(:watched_folder_keep_originals).and_return(true) }

      it "leaves originals in place and imports each file once" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "keep.png")
          File.binwrite(path, DamSpecHelpers::PNG)

          first = scan(dir)
          second = scan(dir)

          expect(File.exist?(path)).to be(true)
          expect(Dam::Asset.unscoped.where(tenant: tenant, original_path: path).count).to eq(1)
          expect(first).to have_attributes(files_processed: 1, files_skipped: 0)
          expect(second).to have_attributes(files_processed: 0, files_skipped: 1)
          expect(Dam::WatchFolderNotification.where(type: "scan_completed").count).to eq(1)
        end
      end

      it "works with a read-only folder" do
        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "ro.png"), DamSpecHelpers::PNG)
          File.chmod(0o555, dir)

          expect(scan(dir)).to have_attributes(status: "completed", files_processed: 1, errors_count: 0)
        ensure
          File.chmod(0o755, dir)
        end
      end
    end
  end
end
