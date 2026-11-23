class Dam::Api::V1::DropZonesController < Dam::Api::V1::BaseController
  before_action :set_drop_zone, only: [ :show, :update, :destroy, :subscribe, :unsubscribe, :files, :upload ]
  before_action :ensure_owner_or_subscriber, only: [ :show, :files ]
  before_action :ensure_owner, only: [ :update, :destroy ]
  before_action :ensure_owner_or_subscriber_for_upload, only: [ :upload ]

  # GET /api/v1/drop_zones
  def index
    # Get owned drop zones (already scoped through user which is tenant-scoped)
    owned_drop_zones = current_user.owned_drop_zones.active

    # Get subscribed drop zones (already scoped through user which is tenant-scoped)
    subscribed_drop_zones = current_user.subscribed_drop_zones.active

    # Combine both collections and apply includes and ordering
    @drop_zones = tenant_scope(Dam::DropZone).where(id: owned_drop_zones.select(:id))
                          .or(tenant_scope(Dam::DropZone).where(id: subscribed_drop_zones.select(:id)))
                          .includes(:owner, :drop_zone_subscriptions)
                          .order(created_at: :desc)

    render json: {
      drop_zones: @drop_zones.map { |dz| drop_zone_serializer(dz) },
      meta: {
        total: @drop_zones.count,
        owned: current_user.owned_drop_zones.active.count,
        subscribed: current_user.subscribed_drop_zones.active.count
      }
    }
  end

  # GET /api/v1/drop_zones/:id
  def show
    render json: {
      drop_zone: drop_zone_serializer(@drop_zone, include_files: true),
      recent_files: @drop_zone.recent_files(10).map { |f| drop_zone_file_serializer(f) }
    }
  end

  # POST /api/v1/drop_zones
  def create
    @drop_zone = current_user.owned_drop_zones.build(drop_zone_params)
    # Ensure tenant is set (should be set by ApplicationRecord callback, but set explicitly for safety)
    if @drop_zone.tenant.nil? && Dam.current_tenant
      @drop_zone.tenant = Dam.current_tenant
    end
    # Fallback: set tenant_id directly if tenant object assignment didn't work
    if @drop_zone.tenant_id.nil? && Dam.current_tenant
      @drop_zone.tenant_id = Dam.current_tenant.id
    end

    if @drop_zone.save
      render json: {
        drop_zone: drop_zone_serializer(@drop_zone),
        message: "Drop zone created successfully"
      }, status: :created
    else
      render json: {
        errors: @drop_zone.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/drop_zones/:id
  def update
    if @drop_zone.update(drop_zone_params)
      render json: {
        drop_zone: drop_zone_serializer(@drop_zone),
        message: "Drop zone updated successfully"
      }
    else
      render json: {
        errors: @drop_zone.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/drop_zones/:id
  def destroy
    @drop_zone.destroy
    render json: { message: "Drop zone deleted successfully" }
  end

  # POST /api/v1/drop_zones/:id/subscribe
  def subscribe
    notification_preferences = params[:notification_preferences] || {}

    begin
      subscription = @drop_zone.subscribe_user!(current_user, notification_preferences)
      render json: {
        subscription: {
          id: subscription.id,
          drop_zone_id: subscription.drop_zone_id,
          user_id: subscription.user_id,
          notification_preferences: subscription.notification_preferences_hash,
          subscribed_at: subscription.subscribed_at
        },
        message: "Successfully subscribed to drop zone"
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: {
        errors: e.record.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/drop_zones/:id/unsubscribe
  def unsubscribe
    @drop_zone.unsubscribe_user!(current_user)
    render json: { message: "Successfully unsubscribed from drop zone" }
  end

  # GET /api/v1/drop_zones/:id/files
  def files
    page = params[:page] || 1
    per_page = params[:per_page] || 20

    @files = @drop_zone.drop_zone_files
                      .includes(:asset, :uploaded_by)
                      .order(uploaded_at: :desc)
                      .offset((page.to_i - 1) * per_page.to_i)
                      .limit(per_page.to_i)

    render json: {
      files: @files.map { |f| drop_zone_file_serializer(f) },
      meta: {
        total: @drop_zone.file_count,
        page: page.to_i,
        per_page: per_page.to_i,
        total_pages: (@drop_zone.file_count.to_f / per_page.to_i).ceil
      }
    }
  end

  # POST /api/v1/drop_zones/:id/upload
  def upload
    Rails.logger.info "Drop Zone Upload: Starting upload for drop zone #{@drop_zone.id} by user #{current_user.id}"

    # Handle both single file and multiple files
    files = if params[:file].present?
      [ params[:file] ]
    elsif params[:files].present?
      params[:files]
    else
      []
    end

    Rails.logger.info "Drop Zone Upload: Files received: #{files.count}"

    unless files.any?
      Rails.logger.warn "Drop Zone Upload: No files provided"
      return render json: { errors: [ "No files provided" ] }, status: :bad_request
    end

    uploaded_files = []
    errors = []

    files.each do |file|
      begin
        Rails.logger.info "Drop Zone Upload: Processing file #{file.original_filename} (#{file.size} bytes)"
        Rails.logger.info "Drop Zone Upload: File content type: #{file.content_type}"
        Rails.logger.info "Drop Zone Upload: File MIME type: #{file.content_type}"

        # Create the asset directly using Dam::Asset to avoid association autoloading issues
        asset = Dam::Asset.new(
          user_id: current_user.id,
          name: file.original_filename,
          file: file,
          tenant_id: Dam.current_tenant.id
        )
        # Ensure tenant is set (should be set by ApplicationRecord callback, but set explicitly for safety)
        asset.tenant = Dam.current_tenant unless asset.tenant
        # Fallback: set tenant_id directly if tenant object assignment didn't work
        asset.tenant_id = Dam.current_tenant.id if asset.tenant_id.nil? && Dam.current_tenant

        if asset.save
          Rails.logger.info "Drop Zone Upload: Asset created successfully with ID #{asset.id}"
          Rails.logger.info "Drop Zone Upload: Asset file type: #{asset.file_type}"

          # Check if drop zone accepts this file type
          unless @drop_zone.accepts_file_type?(asset.file_type)
            error_msg = "File type '#{asset.file_type}' not accepted by this drop zone. Accepted types: #{@drop_zone.accepted_file_types_array.join(', ')}"
            Rails.logger.warn "Drop Zone Upload: #{error_msg}"
            errors << error_msg
            # Clean up the asset
            asset.destroy
            next
          end

          # Create the drop zone file record using the association
          drop_zone_file = @drop_zone.drop_zone_files.build(
            asset: asset,
            uploaded_by: current_user,
            uploaded_at: Time.current,
            tenant: Dam.current_tenant,
            metadata: {
              original_filename: file.original_filename,
              content_type: file.content_type,
              file_size: file.size
            }
          )

          Rails.logger.info "Drop Zone Upload: Attempting to save drop_zone_file with drop_zone_id=#{@drop_zone.id}, asset_id=#{asset.id}, uploaded_by_id=#{current_user.id}, tenant_id=#{Dam.current_tenant&.id}"
          Rails.logger.info "Drop Zone Upload: drop_zone_file valid? #{drop_zone_file.valid?}"
          Rails.logger.info "Drop Zone Upload: drop_zone_file errors: #{drop_zone_file.errors.full_messages.inspect}" unless drop_zone_file.valid?

          begin
            saved = drop_zone_file.save
            Rails.logger.info "Drop Zone Upload: save returned: #{saved}, drop_zone_file.id: #{drop_zone_file.id}, persisted?: #{drop_zone_file.persisted?}, errors: #{drop_zone_file.errors.full_messages.inspect}"

            if saved && drop_zone_file.persisted?
              Rails.logger.info "Drop Zone Upload: Drop zone file record created with ID #{drop_zone_file.id}"
              begin
                uploaded_files << drop_zone_file_serializer(drop_zone_file)
              rescue => serializer_error
                Rails.logger.error "Drop Zone Upload: Serializer error: #{serializer_error.message}"
                Rails.logger.error "Drop Zone Upload: Serializer backtrace: #{serializer_error.backtrace.first(5).join('\n')}"
                # Don't fail the upload if serializer fails - the record was created successfully
                uploaded_files << { id: drop_zone_file.id, asset_id: asset.id, uploaded_at: drop_zone_file.uploaded_at }
              end
            else
              error_msg = "Failed to create drop zone file record for #{file.original_filename}: #{drop_zone_file.errors.full_messages.join(', ')}"
              Rails.logger.error "Drop Zone Upload: #{error_msg}"
              Rails.logger.error "Drop Zone Upload: Full errors: #{drop_zone_file.errors.inspect}"
              errors << error_msg
              # Clean up the asset if drop zone file creation failed
              asset.destroy
            end
          rescue => e
            error_msg = "Failed to create drop zone file record for #{file.original_filename}: #{e.message}"
            Rails.logger.error "Drop Zone Upload: Exception: #{error_msg}"
            Rails.logger.error "Drop Zone Upload: Backtrace: #{e.backtrace.first(10).join('\n')}"
            errors << error_msg
            # Clean up the asset if drop zone file creation failed
            asset.destroy
          end
        else
          error_msg = "Failed to upload #{file.original_filename}: #{asset.errors.full_messages.join(', ')}"
          Rails.logger.error "Drop Zone Upload: #{error_msg}"
          errors << error_msg
        end
      rescue => e
        error_msg = "Failed to upload #{file.original_filename}: #{e.message}"
        Rails.logger.error "Drop Zone Upload: #{error_msg}"
        Rails.logger.error "Drop Zone Upload: Backtrace: #{e.backtrace.join('\n')}" if Rails.env.development?
        errors << error_msg
      end
    end

    if uploaded_files.any?
      render json: {
        uploaded_files: uploaded_files,
        message: "Successfully uploaded #{uploaded_files.count} file(s)",
        errors: errors
      }
    else
      render json: {
        errors: errors
      }, status: :unprocessable_entity
    end
  end

  private

  def set_drop_zone
    @drop_zone = tenant_scope(Dam::DropZone).find(params[:id])
  end

  def ensure_owner_or_subscriber
    unless @drop_zone.can_be_accessed_by?(current_user)
      render json: { error: "Access denied" }, status: :forbidden
    end
  end

  def ensure_owner
    unless @drop_zone.owner == current_user
      render json: { error: "Only the owner can perform this action" }, status: :forbidden
    end
  end

  def ensure_owner_or_subscriber_for_upload
    unless @drop_zone.can_be_accessed_by?(current_user)
      render json: { error: "Access denied - you must be the owner or a subscriber to upload files" }, status: :forbidden
    end
  end

  def drop_zone_params
    params.require(:drop_zone).permit(:name, :description, :is_active, preset_tags: [], settings: {}, accepted_file_types: [])
  end

  def drop_zone_serializer(drop_zone, include_files: false)
    {
      id: drop_zone.id,
      name: drop_zone.name,
      description: drop_zone.description,
      owner: {
        id: drop_zone.owner.id,
        email: drop_zone.owner.email
      },
      preset_tags: drop_zone.preset_tag_names,
      accepted_file_types: drop_zone.accepted_file_types_array,
      is_active: drop_zone.is_active,
      settings: drop_zone.settings_hash,
      file_count: drop_zone.file_count,
      subscriber_count: drop_zone.subscriber_count,
      created_at: drop_zone.created_at,
      updated_at: drop_zone.updated_at,
      recent_files: include_files ? drop_zone.recent_files(5).map { |f| drop_zone_file_serializer(f) } : nil
    }
  end

         def drop_zone_file_serializer(drop_zone_file)
           host = ENV["ACTIVE_STORAGE_HOST"] || "http://localhost:8081"
           {
             id: drop_zone_file.id,
             asset: {
               id: drop_zone_file.asset.id,
               name: drop_zone_file.asset.name,
               filename: drop_zone_file.asset.filename,
               file_size: drop_zone_file.asset.file_size,
               file_size_formatted: drop_zone_file.asset.file_size_formatted,
               content_type: drop_zone_file.asset.content_type,
               file_type: drop_zone_file.asset.file_type,
               download_url: Rails.application.routes.url_helpers.download_url(drop_zone_file.asset.id, host: host),
               thumbnail_url: if drop_zone_file.asset.thumbnail.attached?
                               Rails.application.routes.url_helpers.rails_blob_url(drop_zone_file.asset.thumbnail, host: host)
                              elsif drop_zone_file.asset.image?
                               # For images, use the main file as thumbnail if no thumbnail is attached
                               Rails.application.routes.url_helpers.rails_blob_url(drop_zone_file.asset.file, host: host)
                              else
                               nil
                              end
             },
             uploaded_by: {
               id: drop_zone_file.uploaded_by.id,
               email: drop_zone_file.uploaded_by.email
             },
             uploaded_at: drop_zone_file.uploaded_at,
             metadata: drop_zone_file.metadata_hash
           }
         end
end
