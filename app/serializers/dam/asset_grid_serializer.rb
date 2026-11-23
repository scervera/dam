module Dam
  # Compact asset representation for list and grid views (index, search, recycle bin).
  class AssetGridSerializer
    include JSONAPI::Serializer
    include Dam::FlatSerialization

    set_type :asset

    attributes :id, :name, :file_size, :created_at, :updated_at, :deleted_at,
               :purge_after, :user_id, :exif_data, :image_width, :image_height

    attribute(:file_url) { |asset| AssetUrls.file_url(asset) }
    attribute(:download_url) { |asset| AssetUrls.download_url(asset) }
    attribute(:thumbnail_url) { |asset| AssetUrls.thumbnail_url(asset) }
    attribute(:preview_url) { |asset| AssetUrls.preview_url(asset) }
    attribute(:poster_frame_url) { |asset| AssetUrls.poster_frame_url(asset) }
    attribute(:file_type) { |asset| AssetUrls.mime_type(asset) }
    attribute(:content_type) { |asset| AssetUrls.mime_type(asset) }
    # Dimensions for the details panel (image / video resolution).
    attribute(:image_dimensions) { |asset| asset.respond_to?(:image_dimensions) ? asset.image_dimensions : nil }
    attribute(:video_dimensions) { |asset| AssetUrls.video_dimensions(asset) }
    attribute(:tags) { |asset| Dam::TagSerializer.flat(asset.tags.to_a) }
  end
end
