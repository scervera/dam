module Dam
  class WatchedFolder < ApplicationRecord
    self.table_name = "watched_folders"

    # Associations
    belongs_to :tenant, class_name: Dam.tenant_class_name
    has_many :folder_scans, class_name: "Dam::FolderScan", dependent: :destroy
    has_many :assets, class_name: "Dam::Asset", foreign_key: "watched_folder_id", dependent: :nullify
    has_many :watch_folder_notifications, class_name: "Dam::WatchFolderNotification", dependent: :destroy

    # Validations
    validates :name, presence: true, length: { maximum: 255 }
    validates :path, presence: true, uniqueness: { scope: :tenant_id }
    validates :tenant_id, presence: true
    validates :scan_frequency_value, presence: true,
              numericality: { greater_than: 0, less_than_or_equal_to: 999 }
    validates :scan_frequency_unit, inclusion: { in: %w[minutes hours days] }
    validates :max_file_size_bytes, presence: true,
              numericality: { greater_than: 0, less_than_or_equal_to: 100.gigabytes }

    # Constants
    SCAN_FREQUENCY_UNITS = %w[minutes hours days].freeze

    # Scopes
    scope :active, -> { where(active: true) }
    scope :due_for_scan, -> { where("next_scan_at <= ?", Time.current) }

    # Callbacks
    before_validation :normalize_path
    after_create :schedule_next_scan
    after_update :reschedule_if_frequency_changed

    # Instance methods
    def next_scan_time
      return Time.current if last_scanned_at.nil?

      case scan_frequency_unit
      when "minutes"
        last_scanned_at + scan_frequency_value.minutes
      when "hours"
        last_scanned_at + scan_frequency_value.hours
      when "days"
        last_scanned_at + scan_frequency_value.days
      end
    end

    def scan_frequency_display
      "#{scan_frequency_value} #{scan_frequency_unit}"
    end

    def max_file_size_display
      "#{(max_file_size_bytes / 1.gigabyte.to_f).round(1)} GB"
    end

    def last_scan
      folder_scans.order(:started_at).last
    end

    def unread_notifications_count
      watch_folder_notifications.unread.count
    end

    def recent_notifications(limit = 10)
      watch_folder_notifications.order(created_at: :desc).limit(limit)
    end

    # Auto-tagging methods
    def auto_tag_names
      return [] if auto_tags.blank?
      auto_tags.split(",").map(&:strip).reject(&:blank?)
    end

    def auto_tag_names=(tag_names)
      self.auto_tags = tag_names.is_a?(Array) ? tag_names.join(", ") : tag_names
    end

    def has_auto_tags?
      auto_tag_names.any?
    end

    def can_scan?
      active? && File.directory?(path) && File.readable?(path)
    end

    def scan_now!
      return false unless can_scan?

      Dam::WatchedFolderScanJob.perform_later(id)
      update!(next_scan_at: Time.current)
      true
    end

    private

    def normalize_path
      self.path = File.expand_path(path) if path.present?
    end

    def schedule_next_scan
      update_column(:next_scan_at, next_scan_time)
    end

    def reschedule_if_frequency_changed
      if saved_change_to_scan_frequency_value? || saved_change_to_scan_frequency_unit?
        schedule_next_scan
      end
    end
  end
end
