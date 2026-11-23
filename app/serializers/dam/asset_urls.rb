module Dam
  # URLs and MIME type for an asset, shared by the asset serializers.
  module AssetUrls
    module_function

    def host
      ENV["ACTIVE_STORAGE_HOST"] || "http://localhost:8081"
    end

    def blob_url(attachment)
      Rails.application.routes.url_helpers.rails_blob_url(attachment, host: host)
    end

    def mime_type(asset)
      if asset.file.attached? && asset.file.attachment&.blob
        asset.file.attachment.blob.content_type
      elsif asset.respond_to?(:content_type) && asset.content_type.present?
        asset.content_type
      else
        asset[:content_type]
      end
    end

    def file_url(asset)
      return nil unless asset.file.attached?
      blob_url(asset.file)
    rescue => e
      Rails.logger.error "Error generating file_url for asset #{asset.id}: #{e.message}"
      nil
    end

    # The assets stream endpoint, for video/audio streaming.
    def download_url(asset)
      "#{host}/api/v1/assets/#{asset.id}/stream"
    rescue => e
      Rails.logger.error "Error generating download_url for asset #{asset.id}: #{e.message}"
      nil
    end

    # Images without a generated thumbnail/preview use the original file.
    def thumbnail_url(asset)
      if asset.thumbnail.attached?
        blob_url(asset.thumbnail)
      elsif asset.image?
        blob_url(asset.file)
      end
    end

    def preview_url(asset)
      if asset.respond_to?(:preview) && asset.preview.attached?
        blob_url(asset.preview)
      elsif asset.image?
        blob_url(asset.file)
      end
    end

    def poster_frame_url(asset)
      blob_url(asset.poster_frame) if asset.respond_to?(:poster_frame) && asset.poster_frame.attached?
    end

    def video_dimensions(asset)
      asset.respond_to?(:video_dimensions) ? asset.video_dimensions : nil
    end
  end
end
