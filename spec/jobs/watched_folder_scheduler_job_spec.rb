require "rails_helper"

RSpec.describe Dam::WatchedFolderSchedulerJob do
  it "enqueues its next run in :self_enqueue mode (the default)" do
    expect(Dam.config.watched_folder_scheduler).to eq(:self_enqueue)

    expect { described_class.perform_now }.to have_enqueued_job(described_class)
  end

  it "runs a single pass in :external mode" do
    allow(Dam.config).to receive(:watched_folder_scheduler).and_return(:external)

    expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
  end

  it "starts scans of due folders" do
    allow(Dam.config).to receive(:watched_folder_scheduler).and_return(:external)
    folder = Dam::WatchedFolder.create!(tenant: create_tenant, name: "Inbox", path: Dir.tmpdir, active: true,
                                        scan_frequency_value: 5, scan_frequency_unit: "minutes",
                                        max_file_size_bytes: 10.megabytes, next_scan_at: 1.minute.ago)

    expect { described_class.perform_now }.to have_enqueued_job(Dam::WatchedFolderScanJob).with(folder.id)
  end
end
