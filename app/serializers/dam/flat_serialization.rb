module Dam
  # The DAM API returns flat hashes (id plus attributes, with nested hashes such as an
  # asset's tags) rather than JSON:API documents in most places. Serializers built on
  # JSONAPI::Serializer include this to produce that shape:
  #
  #   Dam::TagSerializer.flat(tag)        # => { id: 1, name: "sermon", ... }
  #   Dam::AssetSerializer.flat(assets)   # => [{ id: 1, ... }, ...]
  #
  # Declare :id as an attribute so it appears in the hash (as an Integer).
  module FlatSerialization
    extend ActiveSupport::Concern

    class_methods do
      def flat(resource, **options)
        data = new(resource, **options).serializable_hash[:data]
        data.is_a?(Array) ? data.map { |item| item[:attributes] } : data&.dig(:attributes)
      end
    end
  end
end
