module Dam
  class TagSerializer
    include JSONAPI::Serializer
    include Dam::FlatSerialization

    set_type :tag

    attributes :id, :name, :created_at, :updated_at
  end
end
