# frozen_string_literal: true

module Dam
  module Ai
    class FaceDetectionJob < ApplicationJob
      queue_as :default

      def perform(asset_id)
        Rails.logger.info "Dam::Ai::FaceDetectionJob: Starting for asset #{asset_id}"
        asset = Dam::Asset.find_by(id: asset_id)
        unless asset
          Rails.logger.warn "Dam::Ai::FaceDetectionJob: Asset #{asset_id} not found"
          return
        end
        unless asset.image?
          Rails.logger.warn "Dam::Ai::FaceDetectionJob: Asset #{asset_id} is not an image, skipping"
          return
        end

        Dam.current_tenant = asset.tenant
        records = Dam::Ai::FaceDetectionService.new(asset: asset).call
        Rails.logger.info "Dam::Ai::FaceDetectionJob: Completed for asset #{asset_id} - #{records.size} face(s) detected"
      rescue StandardError => e
        Rails.logger.error "Dam::Ai::FaceDetectionJob failed for asset #{asset_id}: #{e.message}"
        raise
      ensure
        Dam.current_tenant = nil
      end
    end
  end
end
