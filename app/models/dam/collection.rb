module Dam
  class Collection < ApplicationRecord
    belongs_to :user, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name
    has_many :collection_assets, class_name: "Dam::CollectionAsset", dependent: :destroy
    has_many :assets, through: :collection_assets, class_name: "Dam::Asset"

    # Validations
    validates :name, presence: true
    validates :is_public, inclusion: { in: [ true, false ] }
    validates :tenant_id, presence: true

    # Scopes
    scope :public_collections, -> { where(is_public: true) }
    scope :private_collections, -> { where(is_public: false) }
    scope :recent, -> { order(created_at: :desc) }

    # Methods
    def asset_count
      assets.count
    end

    def add_asset(asset)
      return false if assets.include?(asset)
      collection_assets.create(asset: asset)
    end

    def remove_asset(asset)
      collection_assets.find_by(asset: asset)&.destroy
    end

    def public?
      is_public
    end

    def private?
      !is_public
    end

    def can_be_accessed_by?(user)
      public? || user == self.user || user.admin?
    end
  end
end
