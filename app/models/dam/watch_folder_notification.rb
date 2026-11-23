module Dam
  class WatchFolderNotification < ApplicationRecord
    self.table_name = "watch_folder_notifications"

    # Disable single-table inheritance since we use 'type' for notification types
    self.inheritance_column = nil

    # Constants
    NOTIFICATION_TYPES = %w[
      file_imported
      file_moved
      scan_completed
      scan_failed
      file_import_failed
      file_deletion_failed
      folder_inaccessible
      size_limit_exceeded
    ].freeze

    # Associations
    belongs_to :watched_folder, class_name: "Dam::WatchedFolder"
    belongs_to :tenant, class_name: Dam.tenant_class_name

    # Validations
    validates :type, presence: true, inclusion: { in: NOTIFICATION_TYPES }
    validates :title, presence: true, length: { maximum: 255 }
    validates :message, presence: true
    validates :status, inclusion: { in: %w[unread read dismissed] }
    validates :tenant_id, presence: true

    # Scopes
    scope :unread, -> { where(status: "unread") }
    scope :read, -> { where(status: "read") }
    scope :dismissed, -> { where(status: "dismissed") }
    scope :recent, -> { order(created_at: :desc) }

    # Class methods
    def self.create_file_imported(folder, file_path)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "file_imported",
        title: "File Imported",
        message: "Successfully imported #{File.basename(file_path)}",
        file_path: file_path,
        status: "unread"
      )
    end

    def self.create_file_moved(folder, file_path)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "file_moved",
        title: "File Moved to S3",
        message: "Successfully moved #{File.basename(file_path)} to S3 storage and deleted original",
        file_path: file_path,
        status: "unread"
      )
    end

    def self.create_scan_completed(folder, files_processed, errors_count)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "scan_completed",
        title: "Scan Completed",
        message: "Processed #{files_processed} files with #{errors_count} errors",
        status: "unread"
      )
    end

    def self.create_scan_failed(folder, error_message)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "scan_failed",
        title: "Scan Failed",
        message: "Scan failed: #{error_message}",
        status: "unread",
        metadata: { error: error_message }
      )
    end

    def self.create_file_import_failed(folder, file_path, error_message)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "file_import_failed",
        title: "File Import Failed",
        message: "Failed to import #{File.basename(file_path)}: #{error_message}",
        file_path: file_path,
        status: "unread",
        metadata: { error: error_message }
      )
    end

    def self.create_file_deletion_failed(folder, file_path, error_message)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "file_deletion_failed",
        title: "File Deletion Failed",
        message: "Failed to delete original file #{File.basename(file_path)} after S3 upload: #{error_message}",
        file_path: file_path,
        status: "unread",
        metadata: { error: error_message }
      )
    end

    def self.create_folder_inaccessible(folder, error_message)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "folder_inaccessible",
        title: "Folder Inaccessible",
        message: "Cannot access folder: #{error_message}",
        status: "unread",
        metadata: { error: error_message }
      )
    end

    def self.create_size_limit_exceeded(folder, file_path, file_size)
      create!(
        watched_folder: folder,
        tenant: folder.tenant,
        type: "size_limit_exceeded",
        title: "File Too Large",
        message: "#{File.basename(file_path)} (#{(file_size / 1.megabyte.to_f).round(1)} MB) exceeds size limit",
        file_path: file_path,
        status: "unread",
        metadata: { file_size: file_size, size_limit: folder.max_file_size_bytes }
      )
    end

    # Instance methods
    def unread?
      status == "unread"
    end

    def read?
      status == "read"
    end

    def dismissed?
      status == "dismissed"
    end

    def mark_as_read!
      update!(status: "read")
    end

    def dismiss!
      update!(status: "dismissed")
    end

    def time_ago
      time_diff = Time.current - created_at

      if time_diff < 1.minute
        "Just now"
      elsif time_diff < 1.hour
        "#{time_diff.to_i / 1.minute} minutes ago"
      elsif time_diff < 1.day
        "#{time_diff.to_i / 1.hour} hours ago"
      else
        "#{time_diff.to_i / 1.day} days ago"
      end
    end
  end
end
