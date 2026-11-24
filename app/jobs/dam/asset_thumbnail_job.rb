module Dam
  class AssetThumbnailJob < ApplicationJob
    queue_as { Dam.config.queue_name(:default) }

    def perform(asset_id)
      asset = Dam::Asset.find(asset_id)

      return unless asset.file.attached?
      return if asset.thumbnail.attached?

      # Set tenant context so new thumbnail/preview blobs get tenant-prefixed keys
      Dam.current_tenant = asset.tenant

      begin
        asset.generate_thumbnail
      rescue => e
        Rails.logger.error "Failed to generate thumbnail for asset #{asset_id}: #{e.message}"
        raise e
      ensure
        Dam.current_tenant = nil
      end
    end
  end
end
