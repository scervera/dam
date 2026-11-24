module Dam
  class ThumbnailGenerationJob < ApplicationJob
    queue_as { Dam.config.queue_name(:default) }

    def perform(asset_id)
      asset = Dam::Asset.find(asset_id)

    begin
      Rails.logger.info "Generating thumbnail for asset #{asset_id}"
      asset.generate_thumbnail
      Rails.logger.info "Thumbnail generated successfully for asset #{asset_id}"
      # Run face detection now that thumbnail/preview exist (Rekognition uses compressed variant)
      if asset.image? && ENV.fetch("DAM_FACE_DETECTION_ENABLED", "false").to_s.downcase.in?(%w[true 1 yes])
        Dam::Ai::FaceDetectionJob.perform_later(asset_id)
      end
    rescue => e
      Rails.logger.error "Error generating thumbnail for asset #{asset_id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise e
      end
    end
  end
end
