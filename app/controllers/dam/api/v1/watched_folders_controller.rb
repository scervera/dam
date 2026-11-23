class Dam::Api::V1::WatchedFoldersController < Dam::Api::V1::BaseController
  before_action :set_watched_folder, only: [ :show, :update, :destroy, :scan_now, :scan_history, :notifications ]

  # GET /api/watched_folders
  def index
    @watched_folders = tenant_scope(Dam::WatchedFolder).order(:name)
    response_data = @watched_folders.map do |folder|
      folder.as_json(only: [ :id, :name, :path, :scan_frequency_value, :scan_frequency_unit, :active, :max_file_size_bytes, :auto_tags, :last_scanned_at, :next_scan_at, :total_files_found, :total_files_processed, :total_errors, :created_at, :updated_at ]).merge(
        can_scan: folder.can_scan?,
        scan_frequency_display: folder.scan_frequency_display,
        max_file_size_display: folder.max_file_size_display,
        auto_tag_names: folder.auto_tag_names,
        unread_notifications_count: folder.watch_folder_notifications.where(status: "unread").count
      )
    end
    render json: response_data.to_json
  end

  # GET /api/watched_folders/:id
  def show
    response_data = @watched_folder.as_json(only: [ :id, :name, :path, :scan_frequency_value, :scan_frequency_unit, :active, :max_file_size_bytes, :auto_tags, :last_scanned_at, :next_scan_at, :total_files_found, :total_files_processed, :total_errors, :created_at, :updated_at ]).merge(
      can_scan: @watched_folder.can_scan?,
      scan_frequency_display: @watched_folder.scan_frequency_display,
      max_file_size_display: @watched_folder.max_file_size_display,
      auto_tag_names: @watched_folder.auto_tag_names,
      unread_notifications_count: @watched_folder.watch_folder_notifications.where(status: "unread").count
    )
    render json: response_data.to_json
  end

  # POST /api/watched_folders
  def create
    @watched_folder = Dam::WatchedFolder.new(watched_folder_params)

    if @watched_folder.save
      response_data = @watched_folder.as_json(only: [ :id, :name, :path, :scan_frequency_value, :scan_frequency_unit, :active, :max_file_size_bytes, :auto_tags, :last_scanned_at, :next_scan_at, :total_files_found, :total_files_processed, :total_errors, :created_at, :updated_at ]).merge(
        can_scan: @watched_folder.can_scan?,
        scan_frequency_display: @watched_folder.scan_frequency_display,
        max_file_size_display: @watched_folder.max_file_size_display,
        auto_tag_names: @watched_folder.auto_tag_names,
        unread_notifications_count: 0
      )
      render json: response_data.to_json, status: :created
    else
      render json: { errors: @watched_folder.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/watched_folders/:id
  def update
    if @watched_folder.update(watched_folder_params)
      response_data = @watched_folder.as_json(only: [ :id, :name, :path, :scan_frequency_value, :scan_frequency_unit, :active, :max_file_size_bytes, :auto_tags, :last_scanned_at, :next_scan_at, :total_files_found, :total_files_processed, :total_errors, :created_at, :updated_at ]).merge(
        can_scan: @watched_folder.can_scan?,
        scan_frequency_display: @watched_folder.scan_frequency_display,
        max_file_size_display: @watched_folder.max_file_size_display,
        auto_tag_names: @watched_folder.auto_tag_names,
        unread_notifications_count: @watched_folder.watch_folder_notifications.where(status: "unread").count
      )
      render json: response_data.to_json
    else
      render json: { errors: @watched_folder.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/watched_folders/:id
  def destroy
    @watched_folder.destroy
    head :no_content
  end

  # POST /api/watched_folders/:id/scan_now
  def scan_now
    Rails.logger.info "🔍 SCAN_NOW: Received scan request for folder ID: #{@watched_folder.id}, name: '#{@watched_folder.name}'"
    Rails.logger.info "🔍 SCAN_NOW: Folder can_scan?: #{@watched_folder.can_scan?}"
    Rails.logger.info "🔍 SCAN_NOW: Folder active?: #{@watched_folder.active?}"
    Rails.logger.info "🔍 SCAN_NOW: Folder path exists?: #{File.directory?(@watched_folder.path)}"
    Rails.logger.info "🔍 SCAN_NOW: Folder path readable?: #{File.readable?(@watched_folder.path)}"

    begin
      Rails.logger.info "🚀 SCAN_NOW: Scheduling WatchedFolderScanJob for folder ID: #{@watched_folder.id}"
      Dam::WatchedFolderScanJob.perform_later(@watched_folder.id)
      Rails.logger.info "✅ SCAN_NOW: Job scheduled successfully for folder ID: #{@watched_folder.id}"
      render json: { message: "Scan for '#{@watched_folder.name}' has been scheduled." }, status: :ok
    rescue => e
      Rails.logger.error "❌ SCAN_NOW: Failed to schedule scan for folder ID: #{@watched_folder.id}, error: #{e.message}"
      Rails.logger.error "❌ SCAN_NOW: Error backtrace: #{e.backtrace.join('\n')}"
      render json: { error: "Failed to schedule scan: #{e.message}" }, status: :unprocessable_entity
    end
  end

  # GET /api/watched_folders/:id/scan_history
  def scan_history
    @scans = @watched_folder.folder_scans.order(started_at: :desc).limit(50)
    render json: @scans.map do |scan|
      scan.as_json(only: [ :id, :watched_folder_id, :started_at, :completed_at, :files_found, :files_processed, :files_skipped, :errors_count, :error_details, :status, :created_at, :updated_at ]).merge(
        duration: scan.duration,
        success_rate: scan.success_rate,
        error_rate: scan.error_rate
      )
    end
  end

  # GET /api/watched_folders/:id/notifications
  def notifications
    @notifications = @watched_folder.watch_folder_notifications.order(created_at: :desc).limit(50)
    render json: {
      notifications: @notifications.map do |notification|
        notification.as_json(only: [ :id, :watched_folder_id, :type, :title, :message, :file_path, :status, :metadata, :created_at, :updated_at ]).merge(
          time_ago: notification.time_ago
        )
      end,
      unread_count: @watched_folder.watch_folder_notifications.where(status: "unread").count
    }
  end

  private

  def set_watched_folder
    @watched_folder = tenant_scope(Dam::WatchedFolder).find(params[:id])
  end

  def watched_folder_params
    params.require(:watched_folder).permit(
      :name, :path, :scan_frequency_value, :scan_frequency_unit,
      :active, :max_file_size_bytes, :auto_tags
    )
  end
end
