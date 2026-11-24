module Dam
  class CollectionAsset < ApplicationRecord
    belongs_to :collection, class_name: "Dam::Collection"
    belongs_to :asset, class_name: "Dam::Asset"
    belongs_to :tenant, class_name: Dam.tenant_class_name

    validates :tenant_id, presence: true
  end
end
