module Dam
  class PurgeAssetJob < ApplicationJob
    queue_as { Dam.config.queue_name(:purge) }

    discard_on ActiveRecord::RecordNotFound

    def perform(asset_id)
      asset = Dam::Asset.find(asset_id)
      return if asset.deleted_at.blank?
      return if asset.purge_after.blank? || asset.purge_after.future?

      [ :file, :thumbnail, :preview ].each do |attachment_name|
        attachment = asset.public_send(attachment_name)
        attachment.purge if attachment.attached?
      rescue StandardError => e
        Rails.logger.warn "Failed to purge #{attachment_name} for asset #{asset.id}: #{e.class} - #{e.message}"
      end

      asset.destroy!
    end
  end
end
