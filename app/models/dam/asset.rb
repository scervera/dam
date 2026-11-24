require "exifr/jpeg"
require "mini_exiftool"
require "set"

module Dam
  class Asset < ApplicationRecord
    belongs_to :user, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name
    belongs_to :parent_asset, class_name: "Dam::Asset", optional: true
    enum :visibility_level, { org_wide: 0, team_only: 1, private_visibility: 2, public_link: 3 }

    # Lets the host remove rows that reference this asset (e.g. foreign keys) first.
    before_destroy :announce_destroying, prepend: true

    scope :not_deleted, -> { where(deleted_at: nil) }
    scope :deleted, -> { where.not(deleted_at: nil) }
    scope :purge_due, -> { where.not(purge_after: nil).where("purge_after <= ?", Time.current) }
    has_many :derived_assets,
      class_name: "Dam::Asset",
      foreign_key: :parent_asset_id,
      inverse_of: :parent_asset,
      dependent: :nullify
    belongs_to :watched_folder, required: false, class_name: "Dam::WatchedFolder"
    belongs_to :import_scan, required: false, class_name: "Dam::FolderScan", foreign_key: "import_scan_id"
    has_many :asset_tags, class_name: "Dam::AssetTag", dependent: :destroy
    has_many :tags, through: :asset_tags, class_name: "Dam::Tag"
    has_many :face_detections, class_name: "Dam::FaceDetection", dependent: :destroy

    # DropZone relationships
    has_many :drop_zone_files, class_name: "Dam::DropZoneFile", dependent: :destroy
    has_many :drop_zones, through: :drop_zone_files, class_name: "Dam::DropZone"

    # Active Storage attachments
    has_one_attached :file
    has_one_attached :thumbnail
    has_one_attached :preview

    # Validations
    validates :name, presence: true
    validates :file, presence: true
    validate :acceptable_file_type
    validate :file_size_validation

    after_create :apply_pending_tag_names

    # Extract EXIF data and generate thumbnail after file is attached and transaction is committed
    after_create_commit :extract_exif_data_if_needed, :enqueue_thumbnail_generation
    after_create_commit :enqueue_ai_auto_tagging
    after_create_commit :enqueue_face_detection
    after_create_commit :announce_created

    # Safari bug fix: Override filename if it matches Safari's tempImage pattern
    after_create_commit :fix_safari_filename

    # Invalidate cached asset list responses for this tenant when assets change
    after_commit :bump_asset_list_cache_version, on: [ :create, :update, :destroy ]

    # File type validation
    def acceptable_file_type
      return unless file.attached?

      Rails.logger.info "Asset validation: File #{file.filename} has content type: #{file.content_type}"
      Rails.logger.info "Asset validation: Accepted types include: #{accepted_types.include?(file.content_type)}"

      unless file.content_type.in?(accepted_types)
        Rails.logger.error "Asset validation: File type #{file.content_type} not in accepted types: #{accepted_types.join(', ')}"
        errors.add(:file, "must be a valid file type. Accepted types: #{accepted_types.join(', ')}")
      end
    end

    # File size validation - uses configurable max file size (default 2.5GB)
    def file_size_validation
      return unless file.attached?

      max_size = max_file_size_limit
      if file.byte_size > max_size
        max_size_gb = (max_size / 1.gigabyte.to_f).round(2)
        errors.add(:file, "size must be less than #{max_size_gb}GB")
      end
    end

    # Get maximum file size limit (configurable via ENV, default 2.5GB)
    def self.max_file_size_limit
      # Check ENV variable first (for easy configuration)
      if ENV["DAM_MAX_FILE_SIZE_GB"].present?
        ENV["DAM_MAX_FILE_SIZE_GB"].to_f.gigabytes
      else
        2.5.gigabytes
      end
    end

    def max_file_size_limit
      self.class.max_file_size_limit
    end

    # Accepted file types
    def accepted_types
      %w[
        image/jpeg image/png image/gif image/webp image/tiff image/bmp image/heic image/heif
        video/mp4 video/avi video/mov video/quicktime video/x-m4v video/m4v video/wmv video/flv video/webm
        audio/mpeg audio/wav audio/x-wav audio/ogg audio/mp3 audio/aac audio/flac
        audio/mp4 audio/m4a audio/x-m4a audio/3gpp audio/x-3gpp
        audio/wma audio/x-ms-wma audio/x-ms-wax audio/x-ms-wmv
        audio/amr audio/x-amr audio/3gpp2 audio/x-3gpp2
        audio/opus audio/x-opus audio/vorbis audio/x-vorbis
        audio/speex audio/x-speex audio/gsm audio/x-gsm
        audio/basic audio/au audio/x-au audio/snd audio/x-snd
        audio/midi audio/x-midi audio/mid audio/x-mid
        audio/rmi audio/x-rmi audio/x-aiff audio/aiff
        audio/x-pn-realaudio audio/x-pn-realaudio-plugin
        audio/x-realaudio audio/x-pn-aiff audio/x-pn-wav
        audio/x-pn-windows-acm audio/x-pn-windows-pcm
        audio/x-pn-windows-wma audio/x-pn-windows-wmv
        application/pdf
        text/plain text/csv text/html
        application/msword application/vnd.openxmlformats-officedocument.wordprocessingml.document
        application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
        application/vnd.ms-powerpoint application/vnd.openxmlformats-officedocument.presentationml.presentation
      ]
    end

    # File type categorization
    def file_type
      return nil unless file.attached?

      filename = file.filename.to_s.downcase
      if filename.ends_with?(".heic") || filename.ends_with?(".heif")
        return "image"
      end

      content_type = file.content_type
      if content_type.start_with?("image/")
        "image"
      elsif content_type.start_with?("video/")
        "video"
      elsif content_type.start_with?("audio/")
        "audio"
      elsif content_type == "application/pdf"
        "pdf"
      else
        "document"
      end
    end

    def file_size
      file.attached? ? file.byte_size : 0
    end

    def filename
      file.attached? ? file.filename.to_s : nil
    end

    def content_type
      file.attached? ? file.content_type : nil
    end

    def file_size_formatted
      return "0 Bytes" if file_size == 0

      units = %w[Bytes KB MB GB TB]
      exp = (Math.log(file_size) / Math.log(1024)).to_i
      exp = [ exp, units.length - 1 ].min

      "#{(file_size / 1024.0**exp).round(2)} #{units[exp]}"
    end

    def generate_thumbnail
      return unless file.attached?

      if image?
        generate_image_thumbnail
      elsif video?
        generate_video_thumbnail
      end
    end

    def generate_thumbnail_if_needed
      return unless file.attached?
      return if thumbnail.attached?

      generate_thumbnail
    end

    def enqueue_thumbnail_generation
      return unless file.attached?
      return if thumbnail.attached? && (preview.attached? || !image?)

      if requires_thumbnail?
        begin
          Dam::ThumbnailGenerationJob.perform_later(id)
        rescue => e
          Rails.logger.error "Failed to enqueue thumbnail generation for asset #{id}: #{e.message}"
          begin
            generate_thumbnail
          rescue => sync_error
            Rails.logger.error "Failed to generate thumbnail synchronously for asset #{id}: #{sync_error.message}"
          end
        end
      end
    end

    def enqueue_ai_auto_tagging
      return unless image?
      return unless file.attached?
      return if ai_auto_tagged_at.present?
      return unless Dam.ai_tagging_enabled?

      Dam::Ai::AutoTaggingJob.perform_later(id)
    rescue StandardError => e
      Rails.logger.error "Failed to enqueue AI auto-tagging for asset #{id}: #{e.message}"
    end

    def enqueue_face_detection
      return unless image?
      return unless file.attached?
      return unless ENV.fetch("DAM_FACE_DETECTION_ENABLED", "false").to_s.downcase.in?(%w[true 1 yes])

      Dam::Ai::FaceDetectionJob.perform_later(id)
    rescue StandardError => e
      Rails.logger.error "Failed to enqueue face detection for asset #{id}: #{e.message}"
    end

    # Publishes "asset_created.dam" (e.g. for usage metering). A failing subscriber is
    # logged; the asset is already committed.
    def announce_created
      Dam.instrument("asset_created", asset: self)
    rescue StandardError => e
      Rails.logger.error "asset_created.dam subscriber failed for asset #{id}: #{e.message}"
    end

    # Publishes "asset_destroying.dam" before the row is deleted. Errors abort the destroy.
    def announce_destroying
      Dam.instrument("asset_destroying", asset: self)
    end

    def image?
      file_type == "image"
    end

    def video?
      file_type == "video"
    end

    def audio?
      file_type == "audio"
    end

    def pdf?
      file_type == "pdf"
    end

    def document?
      file_type == "document"
    end

    def auto_imported?
      auto_imported == true
    end

    def requires_thumbnail?
      image? || video? || pdf?
    end

    def derivative?
      parent_asset_id.present?
    end

    def soft_delete!(retention_days: Dam.config.asset_retention_days.call)
      update!(
        deleted_at: Time.current,
        purge_after: retention_days.days.from_now
      )
    end

    def restore_from_recycle_bin!
      update!(deleted_at: nil, purge_after: nil)
    end

    def root_asset
      current = self
      seen = Set.new

      while current.parent_asset_id.present? && !seen.include?(current.id)
        seen << current.id
        current = current.parent_asset
        break unless current
      end

      current || self
    end

    def lineage_identifier
      lineage_id.presence || root_asset.id.to_s
    end

    def lineage_assets
      lid = lineage_identifier
      self.class
        .where(tenant_id: tenant_id)
        .where("dam_assets.lineage_id = :lineage_id OR dam_assets.id::text = :lineage_id", lineage_id: lid)
    end

    def add_tag(tag_name)
      tag = Dam::Tag.find_or_create_by(name: tag_name, tenant: tenant) do |t|
        t.tenant = tenant
      end
      return unless tag&.persisted?

      asset_tags.find_or_create_by(tag: tag, tenant: tenant) do |at|
        at.tenant = tenant
      end
    end

    def remove_tag(tag_name)
      tag = Dam::Tag.where(tenant: tenant).find_by(name: tag_name)
      asset_tags.find_by(tag: tag)&.destroy if tag
    end

    def tag_names=(names)
      @pending_tag_names = Array(names).map { |name| name.to_s.strip.downcase }.reject(&:blank?).uniq
    end

    def tag_names
      tags.pluck(:name)
    end

    def apply_pending_tag_names
      return if @pending_tag_names.blank?

      @pending_tag_names.each { |name| add_tag(name) }
      @pending_tag_names = nil
    end

    def image_dimensions
      return nil unless image? && image_width && image_height
      { width: image_width, height: image_height }
    end

    def video_dimensions
      return nil unless video? && has_attribute?(:video_width) && video_width.present? && video_height.present?
      { width: video_width, height: video_height }
    end

    def exif_data
      return nil unless image? && read_attribute(:exif_data).present?
      JSON.parse(read_attribute(:exif_data)) rescue nil
    end

    def generate_video_thumbnail(timestamp: nil)
      require "streamio-ffmpeg"

      temp_video = Tempfile.new([ "video", File.extname(file.filename.to_s) ])
      temp_video.binmode
      temp_video.write(file.download)
      temp_video.rewind

      temp_thumbnail = Tempfile.new([ "thumb", ".jpg" ])

      begin
        movie = FFMPEG::Movie.new(temp_video.path)

        time = if timestamp.present?
                 timestamp.to_f
        else
                 [ 1.0, movie.duration * 0.1 ].min
        end

        time = [ [ time, 0 ].max, movie.duration - 0.1 ].min if movie.duration

        movie.screenshot(temp_thumbnail.path, { seek_time: time, resolution: "1280x720" })

        thumbnail.purge if thumbnail.attached?

        thumbnail.attach(
          io: File.open(temp_thumbnail.path),
          filename: "thumb_#{file.filename.base}.jpg",
        content_type: "image/jpeg",
        service_name: Dam.config.storage_service_for.call("derivative")
        )

        # Store video dimensions for details display (e.g. 1920x1080, 720p)
        if movie.width.to_i.positive? && movie.height.to_i.positive? && has_attribute?(:video_width)
          update_columns(video_width: movie.width.to_i, video_height: movie.height.to_i)
        end

        Rails.logger.info "Generated video thumbnail for asset #{id} at timestamp #{time}s (1280x720)"
      rescue => e
        Rails.logger.error "Error generating video thumbnail for asset #{id}: #{e.message}"
      ensure
        temp_video.close
        temp_video.unlink
        temp_thumbnail.close
        temp_thumbnail.unlink
      end
    end

    private

    def bump_asset_list_cache_version
      return if tenant_id.blank?

      key = "dam:assets:list:v1:tenant:#{tenant_id}:ver"
      Rails.cache.increment(key, 1, initial: 1)
    rescue => e
      Rails.logger.warn "Failed to bump asset list cache version for tenant #{tenant_id}: #{e.message}"
    end

    def generate_image_thumbnail
      temp_file = Tempfile.new([ "image", File.extname(file.filename.to_s) ])
      temp_file.binmode
      temp_file.write(file.download)
      temp_file.rewind
      temp_file.close

      # Ensure dimensions are set (from file header); works for all images including generated graphics with no EXIF
      if image_width.blank? || image_height.blank?
        begin
          require "vips"
          img = Vips::Image.new_from_file(temp_file.path, access: :sequential)
          update_columns(image_width: img.width, image_height: img.height)
          Rails.logger.info "Set image dimensions from file for asset #{id}: #{img.width}x#{img.height}"
        rescue => e
          Rails.logger.warn "Could not read image dimensions for asset #{id}: #{e.message}"
        end
      end

      # Generate thumbnail (200x200 for grid view)
      processed_thumbnail = ImageProcessing::Vips
                        .source(temp_file.path)
                        .resize_to_limit(200, 200)
                        .convert("jpg")
                        .call

      thumbnail.attach(
        io: File.open(processed_thumbnail.path),
        filename: "thumb_#{file.filename.base}.jpg",
        content_type: "image/jpeg",
        service_name: Dam.config.storage_service_for.call("derivative")
      )

      # Generate preview (1920x1920 for detail view)
      processed_preview = ImageProcessing::Vips
                        .source(temp_file.path)
                        .resize_to_limit(1920, 1920)
                        .convert("jpg")
                        .call

      preview_file = File.open(processed_preview.path)
      preview.attach(
        io: preview_file,
        filename: "preview_#{file.filename.base}.jpg",
        content_type: "image/jpeg",
        service_name: Dam.config.storage_service_for.call("derivative")
      )
      preview_file.close

      Rails.logger.info "Generated thumbnail and preview for asset #{id}"
    rescue => e
      Rails.logger.error "Error generating image thumbnail/preview for asset #{id}: #{e.message}"
    ensure
      temp_file&.unlink
      processed_thumbnail&.unlink if processed_thumbnail.respond_to?(:unlink)
      processed_preview&.unlink if processed_preview.respond_to?(:unlink)
    end

    def fix_safari_filename
      return unless file.attached?
      return unless name.present?

      current_filename = file.filename.to_s
      if current_filename.match?(/^tempImage[a-zA-Z0-9]+\.heic$/i)
        Rails.logger.info "🔧 SAFARI_FIX: Detected Safari-modified filename: #{current_filename}"
        Rails.logger.info "🔧 SAFARI_FIX: Asset name field: #{name}"

        name_is_valid = !name.match?(/^tempImage[a-zA-Z0-9]+\.heic$/i) &&
                        name != current_filename &&
                        name != "image.jpg" &&
                        name.length > 0 &&
                        name != current_filename

        if name_is_valid
          begin
            blob = file.blob
            if blob.present?
              blob.update(filename: name)

              if blob.content_type == "image/heic" && name.downcase.match(/\.(jpg|jpeg)$/)
                blob.update(content_type: "image/jpeg")
              end

              Rails.logger.info "✅ SAFARI_FIX: Updated blob filename from #{current_filename} to #{name}"
            end
          rescue => e
            Rails.logger.error "❌ SAFARI_FIX: Failed to fix filename: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
          end
        else
          Rails.logger.warn "⚠️ SAFARI_FIX: Name field (#{name}) is not valid - not updating blob filename"
          Rails.logger.warn "⚠️ SAFARI_FIX: Keeping tempImage filename: #{current_filename}"
        end
      end
    end

    def extract_exif_data_if_needed
      return unless image? && file.attached?
      return if exif_data.present?

      exif_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info "⏱ ASSET_UPLOAD_PERF: exif_start asset_id=#{id} filename=#{file.filename}"

      begin
        file.open do |temp_file|
          filename_lower = file.filename.to_s.downcase
          extracted_data = {}

          if filename_lower.ends_with?(".heic", ".heif") || file.content_type.in?([ "image/heic", "image/heif" ])
            Rails.logger.info "🔄 Extracting EXIF from HEIC file: #{file.filename}"
            exif = MiniExiftool.new(temp_file.path)
            extracted_data = extract_exif_from_mini_exiftool(exif)
            Rails.logger.info "✅ HEIC EXIF extracted for #{file.filename}: #{extracted_data.keys.join(', ')}" if extracted_data.any?

          elsif filename_lower.ends_with?(".jpg", ".jpeg") || file.content_type.in?([ "image/jpeg", "image/jpg" ])
            Rails.logger.info "🔄 Extracting EXIF from JPEG file: #{file.filename}"
            exif = EXIFR::JPEG.new(temp_file.path)
            if exif && exif.exif?
              extracted_data = extract_exif_from_exifr(exif)
              Rails.logger.info "✅ JPEG EXIF extracted for #{file.filename}: #{extracted_data.keys.join(', ')}" if extracted_data.any?
            end
            # Fallback: JFIF (and other) resolution when EXIF has none (e.g. exported/generated JPEGs)
            if extracted_data[:x_resolution].blank? && extracted_data[:y_resolution].blank?
              merge_resolution_from_mini_exiftool!(temp_file.path, extracted_data)
            end

          elsif filename_lower.ends_with?(".png") || file.content_type == "image/png"
            # PNG has no EXIF; resolution can be in pHYs chunk. ExifTool reads it.
            Rails.logger.info "🔄 Extracting resolution from PNG file: #{file.filename}"
            merge_resolution_from_mini_exiftool!(temp_file.path, extracted_data)
            Rails.logger.info "✅ PNG resolution extracted for #{file.filename}: #{extracted_data.keys.join(', ')}" if extracted_data.any?

          else
            # Other formats (WebP, GIF, etc.): try ExifTool for resolution where supported
            Rails.logger.info "🔄 Trying ExifTool for image metadata: #{file.filename} (#{file.content_type})"
            merge_resolution_from_mini_exiftool!(temp_file.path, extracted_data)
            Rails.logger.info "✅ Metadata extracted for #{file.filename}: #{extracted_data.keys.join(', ')}" if extracted_data.any?
          end

          if extracted_data.any?
            update_column(:exif_data, extracted_data.to_json)
          end
          # Set dimensions from file when missing (client may not have sent them; works for all image formats)
          set_dimensions_from_mini_exiftool!(temp_file.path)
        end
        exif_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - exif_start
        Rails.logger.info "⏱ ASSET_UPLOAD_PERF: exif_done asset_id=#{id} in #{exif_elapsed.round(3)}s"
      rescue => e
        Rails.logger.error "❌ EXIF extraction failed for #{file.filename}: #{e.message}"
        exif_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - exif_start
        Rails.logger.info "⏱ ASSET_UPLOAD_PERF: exif_failed asset_id=#{id} in #{exif_elapsed.round(3)}s"
      end
    end

    # Reads XResolution/YResolution/ResolutionUnit from file via ExifTool (JFIF for JPEG, pHYs for PNG, etc.)
    def merge_resolution_from_mini_exiftool!(path, data)
      exif = MiniExiftool.new(path)
      if exif.respond_to?(:x_resolution) && exif.x_resolution.present?
        data[:x_resolution] = exif.x_resolution.to_f
      end
      if exif.respond_to?(:y_resolution) && exif.y_resolution.present?
        data[:y_resolution] = exif.y_resolution.to_f
      end
      if exif.respond_to?(:resolution_unit) && exif.resolution_unit.present?
        data[:resolution_unit] = exif.resolution_unit.to_i
      end
      data
    end

    # Set image_width/image_height from ExifTool when missing (works for PNG, WebP, JPEG, etc.)
    def set_dimensions_from_mini_exiftool!(path)
      return if image_width.present? && image_height.present?
      exif = MiniExiftool.new(path)
      w = exif.respond_to?(:image_width) && exif.image_width.present? ? exif.image_width.to_i : nil
      h = exif.respond_to?(:image_height) && exif.image_height.present? ? exif.image_height.to_i : nil
      return unless w.to_i.positive? && h.to_i.positive?
      update_columns(image_width: w, image_height: h)
      Rails.logger.info "Set image dimensions from ExifTool for asset #{id}: #{w}x#{h}"
    end

    def extract_exif_from_exifr(exif)
      data = {}

      data[:camera_make] = exif.make if exif.make
      data[:camera_model] = exif.model if exif.model
      data[:lens_model] = exif.lens_model if exif.respond_to?(:lens_model) && exif.lens_model

      data[:aperture] = exif.f_number.to_f if exif.f_number
      data[:shutter_speed] = exif.exposure_time if exif.exposure_time
      data[:iso] = exif.iso_speed_ratings if exif.iso_speed_ratings
      data[:focal_length] = exif.focal_length.to_f if exif.focal_length

      data[:flash] = exif.flash if exif.flash
      data[:white_balance] = exif.white_balance if exif.white_balance
      data[:metering_mode] = exif.metering_mode if exif.metering_mode
      data[:exposure_mode] = exif.exposure_mode if exif.exposure_mode

      data[:date_taken] = exif.date_time.to_s if exif.date_time
      data[:date_digitized] = exif.date_time_digitized.to_s if exif.date_time_digitized

      if exif.gps && exif.gps.latitude && exif.gps.longitude
        data[:gps_latitude] = exif.gps.latitude
        data[:gps_longitude] = exif.gps.longitude
        data[:gps_altitude] = exif.gps.altitude if exif.gps.altitude
      end

      data[:software] = exif.software if exif.software
      data[:artist] = exif.artist if exif.artist
      data[:copyright] = exif.copyright if exif.copyright

      # Resolution/DPI (EXIF ResolutionUnit: 2 = inches → DPI)
      if exif.respond_to?(:x_resolution) && exif.x_resolution
        data[:x_resolution] = exif.x_resolution.respond_to?(:to_f) ? exif.x_resolution.to_f : exif.x_resolution.to_i
      end
      if exif.respond_to?(:y_resolution) && exif.y_resolution
        data[:y_resolution] = exif.y_resolution.respond_to?(:to_f) ? exif.y_resolution.to_f : exif.y_resolution.to_i
      end
      if exif.respond_to?(:resolution_unit) && exif.resolution_unit
        data[:resolution_unit] = exif.resolution_unit.to_i
      end

      data.compact
    end

    def extract_exif_from_mini_exiftool(exif)
      data = {}

      data[:camera_make] = exif.make if exif.make.present?
      data[:camera_model] = exif.model if exif.model.present?
      data[:lens_model] = exif.lens_model if exif.lens_model.present?

      data[:aperture] = exif.f_number.to_f if exif.f_number.present?
      data[:shutter_speed] = exif.shutter_speed if exif.shutter_speed.present?
      data[:iso] = exif.iso.to_i if exif.iso.present?
      data[:focal_length] = exif.focal_length.to_f if exif.focal_length.present?

      data[:flash] = exif.flash if exif.flash.present?
      data[:white_balance] = exif.white_balance if exif.white_balance.present?
      data[:metering_mode] = exif.metering_mode if exif.metering_mode.present?
      data[:exposure_mode] = exif.exposure_mode if exif.exposure_mode.present?

      data[:date_taken] = exif.date_time_original.to_s if exif.date_time_original.present?
      data[:date_digitized] = exif.create_date.to_s if exif.create_date.present?

      if exif.gps_latitude.present? && exif.gps_longitude.present?
        data[:gps_latitude] = exif.gps_latitude.to_f
        data[:gps_longitude] = exif.gps_longitude.to_f
        data[:gps_altitude] = exif.gps_altitude.to_f if exif.gps_altitude.present?
      end

      data[:software] = exif.software if exif.software.present?
      data[:artist] = exif.artist if exif.artist.present?
      data[:copyright] = exif.copyright if exif.copyright.present?

      # Resolution/DPI
      data[:x_resolution] = exif.x_resolution.to_f if exif.respond_to?(:x_resolution) && exif.x_resolution.present?
      data[:y_resolution] = exif.y_resolution.to_f if exif.respond_to?(:y_resolution) && exif.y_resolution.present?
      data[:resolution_unit] = exif.resolution_unit.to_i if exif.respond_to?(:resolution_unit) && exif.resolution_unit.present?

      data.compact
    end
  end
end
