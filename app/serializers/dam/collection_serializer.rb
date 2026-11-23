module Dam
  # JSON:API serializer for Dam::Collection (GET/POST/PATCH /api/v1/collections).
  class CollectionSerializer
    include JSONAPI::Serializer

    set_type :collection

    attributes :id, :name, :description, :is_public, :created_at, :updated_at

    attribute :created_at_formatted do |collection|
      collection.created_at&.strftime("%B %d, %Y at %I:%M %p")
    end

    attribute :updated_at_formatted do |collection|
      collection.updated_at&.strftime("%B %d, %Y at %I:%M %p")
    end

    attribute :asset_count do |collection|
      collection.asset_count
    end

    # Plain ids rather than a JSON:API relationship: asset data is served by
    # /api/v1/assets, and Dam::AssetSerializer is not a JSON:API serializer.
    attribute :asset_ids do |collection|
      collection.asset_ids
    end

    belongs_to :user, serializer: Dam::UserSerializer
  end
end
