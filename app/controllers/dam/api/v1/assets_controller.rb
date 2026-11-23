require "set"

module Dam::Api
  module V1
    class AssetsController < BaseController
      before_action :set_asset, only: [ :show, :update, :destroy, :add_tag, :remove_tag, :auto_tag, :detect_faces, :faces, :generate_poster_frame, :stream, :derivatives, :lineage ]
      before_action :set_recycle_asset, only: [ :restore, :purge ]
      before_action :require_user_or_admin, only: [ :create, :update, :destroy, :restore, :purge, :recycle_bin, :generate_poster_frame, :derivatives ]
      # Allow stream endpoint to work with optional authentication (for video element compatibility)
      skip_before_action :authenticate_user!, only: [ :stream ], raise: false
      skip_before_action :set_default_format, only: [ :stream ], raise: false # Don't force JSON for video streaming
      skip_before_action :ensure_api_tenant_context, only: [ :stream ], raise: false # Set by authenticate_user_for_stream
      skip_before_action :verify_user_tenant, only: [ :stream ], raise: false # Skip tenant verification for stream
      # Runs before set_asset so the asset lookup is scoped to the token's tenant.
      prepend_before_action :authenticate_user_for_stream, only: [ :stream ]

      def index
        pagination = pagination_params
        return unless pagination

        cached = read_asset_list_cache(pagination)
        if cached
          render_success(cached)
          return
        end

        assets = list_assets_scope(pagination)
        return unless assets

        payload = build_asset_list_payload(assets)
        write_asset_list_cache(pagination, payload)
        render_success(payload)
      end

      def show
        authorize @asset
        payload = normalize_file_metadata!(Dam::AssetSerializer.flat(@asset), @asset)
        # Include full tag objects so frontend can display tags (e.g. after auto-tag polling)
        if payload.is_a?(Hash)
          serialized_tags = @asset.tags.map do |tag|
            tag_hash = Dam::TagSerializer.flat(tag)
            tag_hash.is_a?(Hash) ? (tag_hash[:data] || tag_hash) : tag_hash
          end.compact
          payload[:included] = serialized_tags
        end
        render_success(payload)
      end

      def derivatives
        authorize @asset, :derivatives?

        unless @asset.image?
          render_error("Only image assets can be edited", :unprocessable_entity)
          return
        end

        derivative_asset = Dam::CreateImageDerivative.new(
          source_asset: @asset,
          actor: current_user,
          params: derivative_params.to_h
        ).call

        render_success(
          normalize_file_metadata!(Dam::AssetSerializer.flat(derivative_asset), derivative_asset),
          :created
        )
      rescue Dam::CreateImageDerivative::ValidationError => e
        render_error(e.message, :unprocessable_entity)
      rescue ActiveRecord::RecordInvalid => e
        render_error(e.record.errors.full_messages.join(", "), :unprocessable_entity)
      rescue ActionController::ParameterMissing => e
        render_error(e.message, :unprocessable_entity)
      rescue => e
        Rails.logger.error "Failed to create image derivative for asset #{@asset&.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        render_error("Failed to create image derivative: #{e.message}", :internal_server_error)
      end

      def lineage
        authorize @asset, :lineage?

        lineage_id = @asset.lineage_identifier
        lineage_assets = policy_scope(Dam::Asset.where(tenant: Dam.current_tenant))
                         .where("assets.lineage_id = :lineage_id OR assets.id::text = :lineage_id", lineage_id: lineage_id)
                         .includes(file_attachment: :blob, thumbnail_attachment: :blob)
                         .order(created_at: :asc)
                         .to_a

        asset_map = lineage_assets.index_by(&:id)
        ancestors = collect_ancestor_assets(@asset, asset_map)
        descendants = collect_descendant_assets(@asset, lineage_assets)
        siblings = if @asset.parent_asset_id.present?
                     lineage_assets.select { |asset| asset.parent_asset_id == @asset.parent_asset_id && asset.id != @asset.id }
        else
                     []
        end

        render_success(
          {
            lineage_id: lineage_id,
            root_asset_id: @asset.root_asset.id.to_s,
            current_asset_id: @asset.id.to_s,
            ancestors: ancestors.map { |asset| lineage_asset_payload(asset, relation: "ancestor") },
            siblings: siblings.map { |asset| lineage_asset_payload(asset, relation: "sibling") },
            descendants: descendants.map { |asset| lineage_asset_payload(asset, relation: "descendant") },
            relatives: lineage_assets.reject { |asset| asset.id == @asset.id }.map do |asset|
              relation =
                if descendants.any? { |candidate| candidate.id == asset.id }
                  "descendant"
                elsif siblings.any? { |candidate| candidate.id == asset.id }
                  "sibling"
                elsif ancestors.any? { |candidate| candidate.id == asset.id }
                  "ancestor"
                else
                  "relative"
                end

              lineage_asset_payload(asset, relation: relation)
            end
          }
        )
      end

          def create
            # Check if user is disabled
            if current_user.disabled?
              render_error("This account has been disabled. Please contact your administrator.", :forbidden)
              return
            end

            upload_perf_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            Rails.logger.info "⏱ ASSET_UPLOAD_PERF: request_start"

            # Opt-in upload debugging.
            if ENV["ASSET_UPLOAD_VERBOSE_LOGGING"].to_s == "true"
              Rails.logger.info "🔵 ASSET_UPLOAD: Starting asset creation for user #{current_user.id}, tenant #{Dam.current_tenant&.id}"
              Rails.logger.info "🔵 ASSET_UPLOAD: File param present: #{params[:asset][:file].present? rescue false}"
              Rails.logger.info "🔵 ASSET_UPLOAD: Asset params keys: #{asset_params.keys rescue 'error parsing params'}"
            end

            begin
              @asset = current_user.assets.build(asset_params)
              @asset.tenant = Dam.current_tenant unless @asset.tenant
              build_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - upload_perf_start
              Rails.logger.info "⏱ ASSET_UPLOAD_PERF: build_done in #{build_elapsed.round(3)}s"

              authorize @asset

              if asset_params[:tag_names].present?
                authorize @asset, :tag?
              end

              if @asset.save
                save_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - upload_perf_start
                Rails.logger.info "⏱ ASSET_UPLOAD_PERF: save_done in #{save_elapsed.round(3)}s (includes storage upload + DB + after_commit callbacks)"

                render_success(normalize_file_metadata!(Dam::AssetSerializer.flat(@asset), @asset), :created)
                total_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - upload_perf_start
                Rails.logger.info "⏱ ASSET_UPLOAD_PERF: request_complete total=#{total_elapsed.round(3)}s asset_id=#{@asset.id}"
              else
                Rails.logger.error "🔴 ASSET_UPLOAD: Asset save failed. Errors: #{@asset.errors.full_messages.join(', ')}"
                render_error(@asset.errors.full_messages.join(", "))
              end
            rescue => e
              Rails.logger.error "🔴 ASSET_UPLOAD: Exception during asset creation: #{e.class.name} - #{e.message}"
              Rails.logger.error e.backtrace.first(10).join("\n")
              render_error("Failed to create asset: #{e.message}")
            end
          end

      def update
        authorize @asset
        if @asset.update(asset_params)
          render_success(normalize_file_metadata!(Dam::AssetSerializer.flat(@asset), @asset))
        else
          render_error(@asset.errors.full_messages.join(", "))
        end
      end

      def destroy
        unless asset_delete_allowed?(@asset)
          render_error("You do not have permission to delete this asset", :forbidden)
          return
        end

        if Dam.config.soft_delete_enabled.call
          @asset.soft_delete!
          Dam::PurgeAssetJob.set(wait_until: @asset.purge_after).perform_later(@asset.id) if @asset.purge_after.present?
          render_success({ message: "Asset moved to recycle bin", purge_after: @asset.purge_after })
          return
        end

        begin
          # Manually purge attachments with error handling to avoid failures
          # when files don't exist in storage (e.g., after migration to R2)
          purge_attachments_safely(@asset)

          if @asset.destroy
            render_success({ message: "Asset deleted successfully" })
          else
            render_error("Failed to delete asset")
          end
        rescue => e
          Rails.logger.error "Error deleting asset #{@asset.id}: #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")

          # Even if purge fails, try to destroy the asset record
          # The database record should be deleted even if storage cleanup fails
          begin
            @asset.destroy
            render_success({ message: "Asset deleted successfully (storage cleanup had issues)" })
          rescue => destroy_error
            Rails.logger.error "Failed to destroy asset record: #{destroy_error.message}"
            render_error("Failed to delete asset: #{e.message}")
          end
        end
      end

      def recycle_bin
        pagination = pagination_params
        return unless pagination

        assets = Dam::Asset
          .where(tenant: Dam.current_tenant)
          .deleted
          .includes(:tags)
          .order(deleted_at: :desc)
          .page(pagination[:page])
          .per(pagination[:per_page])

        payload = build_asset_list_payload(assets)
        render_success(payload)
      end

      def restore
        unless asset_delete_allowed?(@asset)
          render_error("You do not have permission to restore this asset", :forbidden)
          return
        end

        @asset.restore_from_recycle_bin!
        render_success(normalize_file_metadata!(Dam::AssetSerializer.flat(@asset), @asset))
      end

      def purge
        unless asset_delete_allowed?(@asset)
          render_error("You do not have permission to permanently purge this asset", :forbidden)
          return
        end

        if @asset.purge_after.present? && @asset.purge_after.future? && !current_user.admin? && !current_user.tenant_owner?
          render_error("Asset is still inside the retention window", :forbidden)
          return
        end

        @asset.update!(purge_after: Time.current)
        Dam::PurgeAssetJob.perform_later(@asset.id)
        render_success({ message: "Asset purge queued" })
      end

      def search
        pagination = pagination_params
        return unless pagination

        cached = read_asset_list_cache(pagination)
        if cached
          render_success(cached)
          return
        end

        assets = list_assets_scope(pagination)
        return unless assets

        payload = build_asset_list_payload(assets)
        write_asset_list_cache(pagination, payload)
        render_success(payload)
      end

      def add_tag
        authorize @asset, :tag?
        Rails.logger.info "🔍 ADD_TAG_DEBUG: Starting add_tag for asset #{@asset.id}"
        Rails.logger.info "🔍 ADD_TAG_DEBUG: Tag name param: #{params[:tag_name]}"

        tag_name = params[:tag_name].downcase.strip
        Rails.logger.info "🔍 ADD_TAG_DEBUG: Processed tag name: '#{tag_name}'"

        # Use tenant_scope to ensure we only find/create tags for the current tenant
        tag = tenant_scope(Dam::Tag).find_or_create_by(name: tag_name) do |t|
          t.tenant = Dam.current_tenant
          t.tenant_id = Dam.current_tenant.id
        end
        Rails.logger.info "🔍 ADD_TAG_DEBUG: Tag found/created: #{tag.inspect}"

        unless @asset.tags.include?(tag)
          # Explicitly create AssetTag to ensure tenant_id is set
          asset_tag = Dam::AssetTag.find_or_create_by(
            asset_id: @asset.id,
            tag_id: tag.id,
            tenant_id: Dam.current_tenant.id
          )
          Rails.logger.info "🔍 ADD_TAG_DEBUG: AssetTag created: #{asset_tag.inspect}"
          Rails.logger.info "🔍 ADD_TAG_DEBUG: Tag added to asset"
        else
          Rails.logger.info "🔍 ADD_TAG_DEBUG: Tag already exists on asset"
        end

        reloaded_asset = @asset.reload
        Rails.logger.info "🔍 ADD_TAG_DEBUG: Asset tags after reload: #{reloaded_asset.tags.pluck(:name)}"

        # Serialize asset
        hash = Dam::AssetSerializer.flat(reloaded_asset)
        serialized = hash.is_a?(Hash) ? (hash[:data] || hash) : hash

        # Transform to JSON:API format that frontend expects
        if serialized.is_a?(Hash) && serialized[:id].present?
          attributes = serialized.except(:id, :user, :tenant, :tags)
          normalize_file_attributes!(attributes, reloaded_asset)

          # Serialize tags for included section
          serialized_tags = reloaded_asset.tags.map do |tag|
            tag_hash = Dam::TagSerializer.flat(tag)
            tag_hash.is_a?(Hash) ? (tag_hash[:data] || tag_hash) : tag_hash
          end.compact

          json_api_asset = {
            id: serialized[:id].to_s,
            type: "asset",
            attributes: attributes,
            relationships: {
              user: serialized[:user] ? { data: serialized[:user] } : nil,
              tenant: serialized[:tenant] ? { data: serialized[:tenant] } : nil,
              tags: serialized[:tags] ? { data: serialized[:tags] } : nil
            }
          }

          Rails.logger.info "🔍 ADD_TAG_DEBUG: JSON:API formatted response"
          render_success({
            data: json_api_asset,
            included: serialized_tags
          })
        else
          Rails.logger.error "🔍 ADD_TAG_DEBUG: Failed to serialize asset properly"
          render_error("Failed to serialize asset")
        end
      end

      def auto_tag
        authorize @asset, :tag?
        unless @asset.image?
          render_error("Only image assets can be auto-tagged", :unprocessable_entity)
          return
        end
        unless @asset.file.attached?
          render_error("Asset has no file attached", :unprocessable_entity)
          return
        end
        Dam::Ai::AutoTaggingJob.perform_later(@asset.id)
        render_success({ message: "Auto-tagging started. Tags will update shortly." }, :accepted)
      rescue StandardError => e
        Rails.logger.error "Failed to enqueue auto-tag for asset #{@asset&.id}: #{e.message}"
        render_error("Failed to start auto-tagging: #{e.message}", :internal_server_error)
      end

      def detect_faces
        authorize @asset, :tag?
        unless @asset.image?
          render_error("Only image assets can have faces detected", :unprocessable_entity)
          return
        end
        unless @asset.file.attached?
          render_error("Asset has no file attached", :unprocessable_entity)
          return
        end
        Dam::Ai::FaceDetectionJob.perform_later(@asset.id)
        render_success({ message: "Face detection started. Results will appear shortly." }, :accepted)
      rescue StandardError => e
        Rails.logger.error "Failed to enqueue face detection for asset #{@asset&.id}: #{e.message}"
        render_error("Failed to start face detection: #{e.message}", :internal_server_error)
      end

      def faces
        authorize @asset, :tag?
        detections = @asset.face_detections.includes(:person).order(:id)
        payload = detections.map do |d|
          {
            id: d.id,
            bounding_box: d.bounding_box,
            confidence: d.confidence,
            person_id: d.person_id,
            person_name: d.person&.name,
            suggested_matches: suggested_matches_for(d)
          }
        end
        render_success({ faces: payload })
      end

      def remove_tag
        authorize @asset, :tag?
        tag = Dam::Tag.find(params[:tag_id])
        @asset.tags.delete(tag)

        reloaded_asset = @asset.reload

        # Serialize asset
        hash = Dam::AssetSerializer.flat(reloaded_asset)
        serialized = hash.is_a?(Hash) ? (hash[:data] || hash) : hash

        # Transform to JSON:API format that frontend expects
        if serialized.is_a?(Hash) && serialized[:id].present?
          attributes = serialized.except(:id, :user, :tenant, :tags)
          normalize_file_attributes!(attributes, reloaded_asset)

          # Serialize tags for included section
          serialized_tags = reloaded_asset.tags.map do |t|
            tag_hash = Dam::TagSerializer.flat(t)
            tag_hash.is_a?(Hash) ? (tag_hash[:data] || tag_hash) : tag_hash
          end.compact

          json_api_asset = {
            id: serialized[:id].to_s,
            type: "asset",
            attributes: attributes,
            relationships: {
              user: serialized[:user] ? { data: serialized[:user] } : nil,
              tenant: serialized[:tenant] ? { data: serialized[:tenant] } : nil,
              tags: serialized[:tags] ? { data: serialized[:tags] } : nil
            }
          }

          render_success({
            data: json_api_asset,
            included: serialized_tags
          })
        else
          render_error("Failed to serialize asset")
        end
      end

      def generate_poster_frame
        authorize @asset

        unless @asset.video?
          render_error("Asset must be a video", :unprocessable_entity)
          return
        end

        timestamp = params[:timestamp].to_f

        begin
          @asset.generate_video_thumbnail(timestamp: timestamp)
          reloaded_asset = @asset.reload

          # Serialize asset in JSON:API format
          hash = Dam::AssetSerializer.flat(reloaded_asset)
          serialized = hash.is_a?(Hash) ? (hash[:data] || hash) : hash

          # Transform to JSON:API format that frontend expects
          if serialized.is_a?(Hash) && serialized[:id].present?
            attributes = serialized.except(:id, :user, :tenant, :tags)
            normalize_file_attributes!(attributes, reloaded_asset)

            # Serialize tags for included section
            serialized_tags = reloaded_asset.tags.map do |tag|
              tag_hash = Dam::TagSerializer.flat(tag)
              tag_hash.is_a?(Hash) ? (tag_hash[:data] || tag_hash) : tag_hash
            end.compact

            json_api_asset = {
              id: serialized[:id].to_s,
              type: "asset",
              attributes: attributes,
              relationships: {
                user: serialized[:user] ? { data: serialized[:user] } : nil,
                tenant: serialized[:tenant] ? { data: serialized[:tenant] } : nil,
                tags: serialized[:tags] ? { data: serialized[:tags] } : nil
              }
            }

            render_success({
              data: json_api_asset,
              included: serialized_tags,
              message: "Poster frame generated successfully at #{timestamp}s"
            })
          else
            render_error("Failed to serialize asset after generating poster frame")
          end
        rescue => e
          Rails.logger.error "Error generating poster frame for asset #{@asset.id}: #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")
          render_error("Failed to generate poster frame: #{e.message}", :internal_server_error)
        end
      end

      def stream
        authorize @asset, :download?

        unless @asset.file.attached?
          render_error("File not attached", :not_found)
          return
        end

        # Set CORS headers for video streaming
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Origin, Content-Type, Accept, Authorization, X-Requested-With, Range"
        response.headers["Access-Control-Expose-Headers"] = "Content-Range, Accept-Ranges, Content-Length"
        response.headers["Accept-Ranges"] = "bytes"

        # Get the file data

        file_data = @asset.file.download

        # Determine disposition based on content type
        is_video = @asset.file.content_type&.start_with?("video/")
        is_audio = @asset.file.content_type&.start_with?("audio/")
        disposition = (is_video || is_audio) ? "inline" : "attachment"

        # Handle range requests for video streaming
        if request.headers["Range"].present?
          range_header = request.headers["Range"]
          file_size = file_data.bytesize

          # Parse range header (e.g., "bytes=0-1023")
          if range_header =~ /bytes=(\d+)-(\d*)/
            start_byte = $1.to_i
            end_byte = $2.present? ? $2.to_i : file_size - 1
            end_byte = [ end_byte, file_size - 1 ].min

            content_length = end_byte - start_byte + 1
            response.headers["Content-Range"] = "bytes #{start_byte}-#{end_byte}/#{file_size}"
            response.headers["Content-Length"] = content_length.to_s
            response.headers["Content-Type"] = @asset.file.content_type
            response.status = 206 # Partial Content

            send_data file_data[start_byte..end_byte],
                      filename: @asset.name,
                      type: @asset.file.content_type,
                      disposition: disposition,
                      status: 206
            return
          end
        end

        # Full file response

        response.headers["Content-Type"] = @asset.file.content_type
        response.headers["Content-Disposition"] = "#{disposition}; filename=\"#{@asset.name}\""
        response.headers["Content-Length"] = file_data.bytesize.to_s

        send_data file_data,
                  filename: @asset.name,
                  type: @asset.file.content_type,
                  disposition: disposition
      rescue => e
        Rails.logger.error "Error streaming asset #{@asset.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        render_error("Failed to stream asset: #{e.message}", :internal_server_error)
      end

      private

      def suggested_matches_for(face_detection)
        return [] unless face_detection.face_engine_id.present?
        matches = Dam::Ai::FaceMatchingService.new(face_detection: face_detection).call
        matches.map { |m| { person_id: m[:person].id, person_name: m[:person].name, confidence: m[:confidence] } }
      end

      def pagination_params
        page = params[:page].present? ? params[:page].to_i : 1
        if page < 1
          render_error("Invalid page parameter", :bad_request)
          return nil
        end

        per_page = params[:per_page].present? ? params[:per_page].to_i : 20
        per_page = 20 if per_page < 1
        if per_page > 100
          render_error("per_page must be <= 100", :bad_request)
          return nil
        end

        { page: page, per_page: per_page }
      end

      def list_assets_scope(pagination = nil)
        assets = build_assets_scope
        assets = apply_asset_filters(assets)

        # Preload tags in a separate query so tag filter joins do not limit association tags.
        assets = assets.preload(
          :tags,
          file_attachment: :blob,
          thumbnail_attachment: :blob,
          preview_attachment: :blob
        )
        assets = apply_category_filter(assets)

        pagination ||= pagination_params
        return nil unless pagination
        assets.page(pagination[:page]).per(pagination[:per_page])
      end

      def build_assets_scope
        # Scope to current tenant
        policy_scope(Dam::Asset.where(tenant: Dam.current_tenant))
      end

      # Explicit join for Active Storage: record_id is string, assets.id is bigint (see dashboard_controller)
      def join_file_blob(scope)
        scope.joins(
          "INNER JOIN active_storage_attachments ON active_storage_attachments.record_id::bigint = assets.id AND active_storage_attachments.record_type = 'Dam::Asset' AND active_storage_attachments.name = 'file'"
        ).joins(
          "INNER JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id"
        )
      end

      def apply_asset_filters(assets)
        if params[:file_type].present?
          # Filter by MIME type (matches the `file_type` value the frontend uses, e.g. "image/png")
          ft = params[:file_type].to_s
          if ft.include?("/")
            assets = join_file_blob(assets).where(active_storage_blobs: { content_type: ft })
          end
        end
        assets = assets.joins(:tags).where(tags: { name: params[:tag], tenant: Dam.current_tenant }) if params[:tag].present?

        # Filter by multiple tag IDs (assets that have ANY of the given tags)
        tag_ids = Array(params[:tag_ids]).reject(&:blank?).map(&:to_i).uniq
        if tag_ids.any?
          assets = assets.joins(:tags).where(tags: { id: tag_ids, tenant: Dam.current_tenant }).distinct
        end

        # Enhanced search: asset names, tags, and face recognition (person) names
        if params[:q].present?
          search_query = params[:q].strip
          # Escape special characters for ILIKE to prevent SQL injection
          escaped_query = search_query.gsub(/[%_\\]/, '\\\\\\0')

          # For multi-word queries, match any word (OR logic for words across name/tag/face person)
          words = escaped_query.split(/\s+/).reject(&:blank?)

          if words.length > 1
            # Multi-word: match if ANY word appears in name, tags, or face person name
            name_conditions = words.map { |_word| "assets.name ILIKE ?" }.join(" OR ")
            tag_conditions = words.map { |_word| "tags.name ILIKE ?" }.join(" OR ")
            face_conditions = words.map { |_word| "face_people.name ILIKE ?" }.join(" OR ")
            name_values = words.map { |word| "%#{word}%" }
            tag_values = words.map { |word| "%#{word}%" }
            face_values = words.map { |word| "%#{word}%" }

            assets = assets
              .left_joins(:tags)
              .left_joins(face_detections: :person)
              .where(
                "(#{name_conditions}) OR (#{tag_conditions}) OR (#{face_conditions})",
                *name_values,
                *tag_values,
                *face_values
              ).distinct
          else
            # Single word: fuzzy match on name, tags, or face person name
            search_pattern = "%#{escaped_query}%"
            assets = assets
              .left_joins(:tags)
              .left_joins(face_detections: :person)
              .where(
                "assets.name ILIKE ? OR tags.name ILIKE ? OR face_people.name ILIKE ?",
                search_pattern,
                search_pattern,
                search_pattern
              ).distinct
          end
        end

        assets
      end

      def apply_category_filter(assets)
        return assets unless params[:category].present? && params[:category] != "all"

        assets = join_file_blob(assets)

        case params[:category]
        when "image"
          assets.where("active_storage_blobs.content_type LIKE ?", "image/%")
        when "video"
          assets.where("active_storage_blobs.content_type LIKE ?", "video/%")
        when "audio"
          assets.where("active_storage_blobs.content_type LIKE ?", "audio/%")
        when "document"
          assets.where(active_storage_blobs: { content_type: [ "application/pdf", "text/plain", "text/csv", "text/html", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation" ] })
        else
          assets
        end
      end

      def build_asset_list_payload(assets)
        # Serialize each asset individually and transform to JSON:API format
        assets_array = assets.to_a
        asset_ids = assets_array.map(&:id)

        all_tags = if asset_ids.any?
          Dam::Tag
            .joins(:asset_tags)
            .where(asset_tags: { asset_id: asset_ids, tenant_id: Dam.current_tenant.id })
            .distinct
            .to_a
        else
          []
        end

        serialized_assets = assets_array.map do |asset|
          begin
            hash = Dam::AssetGridSerializer.flat(asset)
            # Serializers' .flat returns the attribute hash directly
            # Check if it's wrapped in :data or return hash directly
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
            # Serializers' .flat returns the attribute hash directly
            # Check if it's wrapped in :data or return hash directly
            result = hash.is_a?(Hash) ? (hash[:data] || hash) : hash
            # Return the result if it's a valid hash (even if id is missing, let frontend handle it)
            result.is_a?(Hash) ? result : nil
          rescue => e
            Rails.logger.error "Error serializing tag #{tag.id}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            nil
          end
        end.compact

        # Build response
        serialized_data = {
          data: serialized_assets,
          included: serialized_tags,
          meta: {
            current_page: assets.current_page,
            total_pages: assets.total_pages,
            total_count: assets.total_count,
            per_page: assets.limit_value,
            has_next_page: assets.next_page.present?,
            has_prev_page: assets.prev_page.present?
          }
        }

        serialized_data
      end

      def asset_list_cache_ttl_seconds
        ENV.fetch("DAM_ASSET_LIST_CACHE_TTL_SECONDS", "300").to_i
      rescue
        300
      end

      def cacheable_asset_list_request?
        asset_list_cache_ttl_seconds > 0 && params[:ts].blank?
      end

      def asset_list_cache_mode
        current_user&.admin? ? "admin" : "user"
      end

      def asset_list_cache_version_key
        "dam:assets:list:v1:tenant:#{Dam.current_tenant.id}:ver"
      end

      def asset_list_cache_version
        Rails.cache.read(asset_list_cache_version_key) || 1
      end

      def asset_list_cache_params_hash(pagination)
        # Stable, minimal cache input. Intentionally excludes :ts (used as a cache-bust param).
        tag_ids_part = Array(params[:tag_ids]).reject(&:blank?).map(&:to_i).sort.join(",")
        parts = [
          "action=#{action_name}",
          "page=#{pagination[:page]}",
          "per_page=#{pagination[:per_page]}",
          "category=#{params[:category].presence || 'all'}",
          "q=#{params[:q].to_s.strip}",
          "tag=#{params[:tag]}",
          "tag_ids=#{tag_ids_part}",
          "file_type=#{params[:file_type]}"
        ]
        Digest::SHA256.hexdigest(parts.join("&"))[0, 24]
      end

      def asset_list_cache_key(pagination)
        tenant_id = Dam.current_tenant.id
        mode = asset_list_cache_mode
        ver = asset_list_cache_version
        params_hash = asset_list_cache_params_hash(pagination)
        "dam:assets:list:v1:tenant:#{tenant_id}:mode:#{mode}:ver:#{ver}:#{params_hash}"
      end

      def read_asset_list_cache(pagination)
        return nil unless cacheable_asset_list_request?
        Rails.cache.read(asset_list_cache_key(pagination))
      end

      def write_asset_list_cache(pagination, payload)
        return unless cacheable_asset_list_request?
        Rails.cache.write(asset_list_cache_key(pagination), payload, expires_in: asset_list_cache_ttl_seconds.seconds)
      end

      # <video> elements can't send an Authorization header, so the stream endpoint also
      # accepts the token as ?token=. A valid token is required.
      def authenticate_user_for_stream
        token = request.headers["Authorization"]&.delete_prefix("Bearer ") || params[:token]
        user = Dam.config.authenticate_token.call(token) if token.present?
        return render_error("Authentication required", :unauthorized) unless user

        tenant = Dam.config.tenant_for_request.call(user, request)
        return render_error("Tenant not found", :not_found) unless tenant

        @current_user = user
        Dam.current_user = user
        Dam.current_tenant = tenant
      end

      def set_asset
        @asset = policy_scope(Dam::Asset.where(tenant: Dam.current_tenant)).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_error("Asset not found", :not_found)
      end

      def set_recycle_asset
        @asset = Dam::Asset.where(tenant: Dam.current_tenant).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_error("Asset not found", :not_found)
      end

      def asset_delete_allowed?(asset)
        return true if current_user.tenant_owner? || current_user.admin?
        current_user.dam_writer? && asset.user_id == current_user.id
      end

      def asset_params
        params.require(:asset).permit(:name, :description, :file, :file_type, :file_size, :mime_type, :metadata, :image_width, :image_height, tag_names: [])
      end

      def derivative_params
        params.require(:derivative).permit(
          :name,
          :description,
          :copy_tags,
          :derivative_kind,
          output: [ :format, :quality ],
          operations: [
            { crop: [ :x, :y, :width, :height ] },
            { resize: [ :width, :height, :mode ] },
            { rotate: [ :degrees ] }
          ]
        )
      end

      def normalize_file_metadata!(payload, asset)
        return payload unless payload.is_a?(Hash)

        if payload.key?(:attributes) && payload[:attributes].is_a?(Hash)
          normalize_file_attributes!(payload[:attributes], asset)
        else
          normalize_file_attributes!(payload, asset)
        end

        payload
      end

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

      def collect_ancestor_assets(asset, asset_map)
        ancestors = []
        seen_ids = Set.new([ asset.id ])
        current = asset

        while current.parent_asset_id.present?
          break if seen_ids.include?(current.parent_asset_id)

          parent = asset_map[current.parent_asset_id] || Dam::Asset.find_by(id: current.parent_asset_id, tenant: Dam.current_tenant)
          break unless parent

          ancestors << parent
          seen_ids << parent.id
          current = parent
        end

        ancestors.reverse
      end

      def collect_descendant_assets(asset, lineage_assets)
        children_by_parent = lineage_assets.group_by(&:parent_asset_id)
        queue = Array(children_by_parent[asset.id])
        descendants = []

        until queue.empty?
          child = queue.shift
          descendants << child
          queue.concat(Array(children_by_parent[child.id]))
        end

        descendants
      end

      def lineage_asset_payload(asset, relation:)
        {
          id: asset.id.to_s,
          parent_asset_id: asset.parent_asset_id&.to_s,
          lineage_id: asset.lineage_identifier,
          derivative_kind: asset.derivative_kind,
          relation: relation,
          name: asset.name,
          file_type: asset.content_type,
          created_at: asset.created_at,
          thumbnail_url: asset_thumbnail_url(asset),
          file_url: asset_file_url(asset)
        }
      end

      def asset_file_url(asset)
        return nil unless asset.file.attached?

        Rails.application.routes.url_helpers.rails_blob_url(asset.file, host: active_storage_host)
      rescue => e
        Rails.logger.error "Error generating file URL for lineage asset #{asset.id}: #{e.message}"
        nil
      end

      def asset_thumbnail_url(asset)
        if asset.thumbnail.attached?
          Rails.application.routes.url_helpers.rails_blob_url(asset.thumbnail, host: active_storage_host)
        elsif asset.image? && asset.file.attached?
          Rails.application.routes.url_helpers.rails_blob_url(asset.file, host: active_storage_host)
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error generating thumbnail URL for lineage asset #{asset.id}: #{e.message}"
        nil
      end

      def active_storage_host
        ENV["ACTIVE_STORAGE_HOST"] || request.base_url
      end

      def purge_attachments_safely(asset)
        # Safely purge all attachments, handling errors gracefully
        # This is important when files don't exist in storage (e.g., after migration to R2)
        [ :file, :thumbnail, :preview ].each do |attachment_name|
          attachment = asset.send(attachment_name)
          if attachment.attached?
            begin
              attachment.purge
            rescue ActiveRecord::RecordNotFound => e
              # Blob already deleted, detach to prevent Active Storage from trying again
              Rails.logger.warn "Blob for #{attachment_name} on asset #{asset.id} already deleted: #{e.message}"
              attachment.detach rescue nil
            rescue => e
              # Other errors (connection issues, etc.) - detach to prevent retry during destroy
              Rails.logger.warn "Failed to purge #{attachment_name} for asset #{asset.id}: #{e.message}"
              attachment.detach rescue nil
            end
          end
        end
      end
    end
  end
end
