# frozen_string_literal: true

module Dam
  module Ai
    class AutoTaggingJob < ApplicationJob
      queue_as :default

      def perform(asset_id)
        asset = Dam::Asset.find_by(id: asset_id)
        unless asset
          Rails.logger.warn "Dam::Ai::AutoTaggingJob: Asset #{asset_id} not found"
          return
        end
        unless asset.image?
          Rails.logger.warn "Dam::Ai::AutoTaggingJob: Asset #{asset_id} is not an image, skipping"
          return
        end

        Dam.current_tenant = asset.tenant
        Dam::Ai::AutoTaggingService.new(asset: asset).call
      rescue StandardError => e
        Rails.logger.error "Dam::Ai::AutoTaggingJob failed for asset #{asset_id}: #{e.message}"
        raise
      ensure
        Dam.current_tenant = nil
      end
    end
  end
end
