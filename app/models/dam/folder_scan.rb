module Dam
  class FolderScan < ApplicationRecord
    self.table_name = "folder_scans"

    # Associations
    belongs_to :watched_folder, class_name: "Dam::WatchedFolder"
    belongs_to :tenant, class_name: Dam.tenant_class_name
    has_many :imported_assets, class_name: "Dam::Asset", foreign_key: "import_scan_id", dependent: :nullify

    # Validations
    validates :started_at, presence: true
    validates :status, inclusion: { in: %w[running completed failed] }
    validates :tenant_id, presence: true

    # Scopes
    scope :completed, -> { where(status: "completed") }
    scope :failed, -> { where(status: "failed") }
    scope :running, -> { where(status: "running") }
    scope :recent, -> { order(started_at: :desc) }

    # Callbacks
    before_create :set_defaults

    # Instance methods
    def duration
      return nil unless completed_at
      completed_at - started_at
    end

    def success_rate
      return 0 if files_found.zero?
      (files_processed.to_f / files_found * 100).round(2)
    end

    def error_rate
      return 0 if files_found.zero?
      (errors_count.to_f / files_found * 100).round(2)
    end

    def completed?
      status == "completed"
    end

    def failed?
      status == "failed"
    end

    def running?
      status == "running"
    end

    def mark_completed!
      update!(
        status: "completed",
        completed_at: Time.current
      )
    end

    def mark_failed!(error_message = nil)
      error_details = error_message ? [ { error: error_message, timestamp: Time.current } ].to_json : nil

      update!(
        status: "failed",
        completed_at: Time.current,
        error_details: error_details
      )
    end

    def add_error(file_path, error_message)
      current_errors = JSON.parse(error_details || "[]")
      current_errors << {
        file_path: file_path,
        error: error_message,
        timestamp: Time.current
      }

      update!(error_details: current_errors.to_json)
      increment!(:errors_count)
    end

    def increment_files_found!
      increment!(:files_found)
    end

    def increment_files_processed!
      increment!(:files_processed)
    end

    def increment_files_skipped!
      increment!(:files_skipped)
    end

    private

    def set_defaults
      self.started_at ||= Time.current
      self.status ||= "running"
    end
  end
end
