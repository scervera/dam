class Dam::Api::V1::SmartFoldersController < Dam::Api::V1::BaseController
  before_action :set_smart_folder, only: [ :show, :update, :destroy, :assets ]

  # GET /api/smart_folders
  def index
    @smart_folders = tenant_scope(Dam::SmartFolder).visible_to(current_user).active.ordered
    # Use inline hash response instead of serializer
    render_success({
      data: @smart_folders.map { |sf| serialize_smart_folder(sf) }
    })
  end

  # GET /api/smart_folders/sidebar
  def sidebar
    # Return 5 smart folders - prefer recently updated, but show any if none are recently updated
    # Order by updated_at desc, then by created_at desc, then by name as fallback
    @smart_folders = tenant_scope(Dam::SmartFolder)
                      .visible_to(current_user)
                      .active
                      .order(updated_at: :desc, created_at: :desc, name: :asc)
                      .limit(5)
    # Use inline hash response instead of serializer
    render_success({
      data: @smart_folders.map { |sf| serialize_smart_folder(sf) }
    })
  end

  # GET /api/smart_folders/:id
  def show
    # Use inline hash response instead of serializer
    render_success({ data: serialize_smart_folder(@smart_folder) })
  end

  # POST /api/smart_folders
  def create
    # Check if user is disabled
    if current_user.disabled?
      render_error("This account has been disabled. Please contact your administrator.", :forbidden)
      return
    end

    # Use Dam::SmartFolder directly to avoid autoloading issues
    @smart_folder = Dam::SmartFolder.new(smart_folder_params.merge(user_id: current_user.id))
    # Ensure tenant is set explicitly
    @smart_folder.tenant = Dam.current_tenant
    @smart_folder.tenant_id = Dam.current_tenant.id

    if @smart_folder.save
      render_success({ data: serialize_smart_folder(@smart_folder) }, :created)
    else
      render_error(@smart_folder.errors.full_messages.join(", "))
    end
  end

  # PATCH/PUT /api/smart_folders/:id
  def update
    if @smart_folder.update(smart_folder_params)
      render_success({ data: serialize_smart_folder(@smart_folder) })
    else
      render json: { errors: @smart_folder.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/smart_folders/:id
  def destroy
    # Check if user can delete this smart folder
    # Users can delete smart folders they created, owners/admins can delete any smart folder
    can_delete = false
    if current_user.tenant_owner? || current_user.admin?
      can_delete = true
    elsif current_user.dam_writer? && @smart_folder.user_id == current_user.id
      can_delete = true
    end

    unless can_delete
      render_error("You do not have permission to delete this smart folder", :forbidden)
      return
    end

    if @smart_folder.destroy
      render_success({ message: "Smart folder deleted successfully" })
    else
      render_error("Failed to delete smart folder")
    end
  end

  # GET /api/smart_folders/:id/assets
  def assets
    # Build assets using smart folder's query logic
    @assets = @smart_folder.assets(current_user).includes(:tags, :user)

    # Handle category filtering
    if params[:category].present? && params[:category] != "all"
      case params[:category]
      when "image"
        @assets = @assets.joins(:file_attachment).joins("JOIN active_storage_blobs ON active_storage_attachments.blob_id = active_storage_blobs.id").where(active_storage_blobs: { content_type: [ "image/jpeg", "image/png", "image/gif", "image/webp", "image/tiff", "image/bmp", "image/heic", "image/heif" ] })
      when "video"
        @assets = @assets.joins(:file_attachment).joins("JOIN active_storage_blobs ON active_storage_attachments.blob_id = active_storage_blobs.id").where(active_storage_blobs: { content_type: [ "video/mp4", "video/avi", "video/mov", "video/quicktime", "video/wmv", "video/flv", "video/webm" ] })
      when "audio"
        @assets = @assets.joins(:file_attachment).joins("JOIN active_storage_blobs ON active_storage_attachments.blob_id = active_storage_blobs.id").where(active_storage_blobs: { content_type: [ "audio/mpeg", "audio/wav", "audio/x-wav", "audio/ogg", "audio/mp3", "audio/aac", "audio/flac", "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/x-3gpp", "audio/x-3gpp2", "audio/wma", "audio/x-ms-wma", "audio/x-ms-wax", "audio/x-ms-wmv", "audio/amr", "audio/x-amr", "audio/opus", "audio/x-opus", "audio/vorbis", "audio/x-vorbis", "audio/speex", "audio/x-speex", "audio/gsm", "audio/x-gsm", "audio/basic", "audio/au", "audio/x-au", "audio/snd", "audio/x-snd", "audio/midi", "audio/x-midi", "audio/mid", "audio/x-mid", "audio/rmi", "audio/x-rmi", "audio/x-aiff", "audio/aiff", "audio/x-pn-realaudio", "audio/x-pn-realaudio-plugin", "audio/x-realaudio", "audio/x-pn-aiff", "audio/x-pn-wav", "audio/x-pn-windows-acm", "audio/x-pn-windows-pcm", "audio/x-pn-windows-wma", "audio/x-pn-windows-wmv" ] })
      when "document"
        @assets = @assets.joins(:file_attachment).joins("JOIN active_storage_blobs ON active_storage_attachments.blob_id = active_storage_blobs.id").where(active_storage_blobs: { content_type: [ "application/pdf", "text/plain", "text/csv", "text/html", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation" ] })
      end
    end

    # Convert relation to array for serialization
    assets_array = @assets.to_a
    all_tags = assets_array.flat_map(&:tags).uniq

    # Serialize each asset individually and transform to JSON:API format (same as AssetsController)
    serialized_assets = assets_array.map do |asset|
      begin
        hash = ::Dam::AssetSerializer.flat(asset)
        # Serializers' .flat returns the attribute hash directly
        serialized = hash.is_a?(Hash) ? (hash[:data] || hash) : hash

        # Transform to JSON:API format that frontend expects
        if serialized.is_a?(Hash) && serialized[:id].present?
          attributes = serialized.except(:id, :user, :tenant, :tags)
          normalize_file_attributes!(attributes, asset)

          {
            id: serialized[:id].to_s,
            type: "asset",
            attributes: attributes,
            relationships: {
              user: serialized[:user] ? { data: serialized[:user] } : nil,
              tenant: serialized[:tenant] ? { data: serialized[:tenant] } : nil,
              tags: serialized[:tags] ? { data: serialized[:tags] } : nil
            }
          }
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error serializing asset #{asset.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        nil
      end
    end.compact

    # Serialize tags
    serialized_tags = all_tags.map do |tag|
      begin
        hash = Dam::TagSerializer.flat(tag)
        result = hash.is_a?(Hash) ? (hash[:data] || hash) : hash
        result.is_a?(Hash) ? result : nil
      rescue => e
        Rails.logger.error "Error serializing tag #{tag.id}: #{e.message}"
        nil
      end
    end.compact

    render_success({
      data: serialized_assets,
      included: serialized_tags
    })
  end

  # POST /api/smart_folders/:id/pin
  def pin
    @smart_folder = tenant_scope(Dam::SmartFolder).visible_to(current_user).find(params[:id])
    @smart_folder.update!(pinned_to_sidebar: true)
    render_success({ data: serialize_smart_folder(@smart_folder) })
  end

  # POST /api/smart_folders/:id/unpin
  def unpin
    @smart_folder = tenant_scope(Dam::SmartFolder).visible_to(current_user).find(params[:id])
    @smart_folder.update!(pinned_to_sidebar: false)
    render_success({ data: serialize_smart_folder(@smart_folder) })
  end

  private

  def set_smart_folder
    @smart_folder = tenant_scope(Dam::SmartFolder).visible_to(current_user).find(params[:id])
  end

  def serialize_smart_folder(smart_folder)
    {
      id: smart_folder.id,
      attributes: {
        name: smart_folder.name,
        description: smart_folder.description,
        tag_criteria: smart_folder.tag_criteria,
        tag_names: smart_folder.tag_names,
        active: smart_folder.active,
        sort_order: smart_folder.sort_order,
        visibility_level: smart_folder.visibility_level,
        match_logic: smart_folder.match_logic,
        color: smart_folder.color,
        pinned_to_sidebar: smart_folder.pinned_to_sidebar,
        shared_user_ids: smart_folder.shared_user_ids_array,
        group_id: smart_folder.group_id,
        user_id: smart_folder.user_id,
        tenant_id: smart_folder.tenant_id,
        asset_count: smart_folder.asset_count(current_user),
        created_at: smart_folder.created_at,
        updated_at: smart_folder.updated_at
      }
    }
  end

  def smart_folder_params
    params.require(:smart_folder).permit(
      :name,
      :description,
      :tag_criteria,
      :active,
      :sort_order,
      :visibility_level,
      :match_logic,
      :color,
      :pinned_to_sidebar,
      :group_id,
      shared_user_ids: []
    )
  end

  # Normalize file attributes (same as AssetsController)
  def normalize_file_attributes!(attributes, asset)
    return attributes unless attributes.is_a?(Hash)

    blob_content_type = asset&.file&.attachment&.blob&.content_type

    if attributes[:content_type].present?
      attributes[:file_type] = attributes[:content_type]
    elsif attributes[:file_type].present? && attributes[:file_type].include?("/")
      attributes[:content_type] = attributes[:file_type]
    elsif blob_content_type.present?
      attributes[:file_type] = blob_content_type
      attributes[:content_type] = blob_content_type
    end

    attributes[:file_category] ||= asset&.file_type
    attributes
  end
end
