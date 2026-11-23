module Dam
  # Full asset representation (show, create, update, tag changes, tag and smart folder
  # listings). Includes the asset's user, tenant and tags unless params[:associations]
  # is false (used when an asset is embedded in another resource).
  class AssetSerializer
    include JSONAPI::Serializer
    include Dam::FlatSerialization

    set_type :asset

    attributes :id, :name, :description, :file_size, :file_size_formatted,
               :filename, :visibility_level, :created_at, :updated_at,
               :image_width, :image_height, :exif_data, :auto_imported, :original_path

    attribute(:file_url) { |asset| AssetUrls.file_url(asset) }
    attribute(:download_url) { |asset| AssetUrls.download_url(asset) }
    attribute(:thumbnail_url) { |asset| AssetUrls.thumbnail_url(asset) }
    attribute(:preview_url) { |asset| AssetUrls.preview_url(asset) }
    attribute(:poster_frame_url) { |asset| AssetUrls.poster_frame_url(asset) }
    attribute(:parent_asset_id) { |asset| asset.parent_asset_id&.to_s }
    attribute(:lineage_id) { |asset| asset.lineage_identifier }
    attribute :derivative_kind
    attribute(:is_derivative) { |asset| asset.parent_asset_id.present? }
    attribute(:file_type) { |asset| AssetUrls.mime_type(asset) }
    attribute(:file_category) { |asset| asset.file_type }
    attribute(:content_type) { |asset| AssetUrls.mime_type(asset) }
    attribute(:video_dimensions) { |asset| AssetUrls.video_dimensions(asset) }

    with_associations = ->(_asset, params) { params[:associations] != false }

    attribute :user, if: with_associations do |asset|
      asset.user && Dam.config.serialize_user.call(asset.user)
    end
    attribute :tenant, if: with_associations do |asset|
      asset.tenant && Dam.config.serialize_tenant.call(asset.tenant)
    end
    attribute :tags, if: with_associations do |asset|
      Dam::TagSerializer.flat(asset.tags.to_a)
    end
  end
end
