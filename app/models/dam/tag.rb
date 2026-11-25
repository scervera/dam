module Dam
  class Tag < ApplicationRecord
    belongs_to :tenant, class_name: Dam.tenant_class_name
    has_many :asset_tags, class_name: "Dam::AssetTag", dependent: :destroy
    has_many :assets, through: :asset_tags, class_name: "Dam::Asset"

    # Callbacks
    before_validation :ensure_tenant_is_set
    after_commit :bump_asset_list_cache_version, on: [ :create, :update, :destroy ]

    # Validations
    validates :name, presence: true, uniqueness: { scope: :tenant_id }, length: { minimum: 2, maximum: 50 }
    validates :name, format: { with: /\A[a-zA-Z0-9\s\-_:]+\z/, message: "can only contain letters, numbers, spaces, hyphens, underscores, and colons" }
    validates :tenant_id, presence: true

    # Scopes
    scope :popular, -> { joins(:asset_tags).group("dam_tags.id").order("COUNT(dam_asset_tags.id) DESC") }
    scope :recent, -> { order(created_at: :desc) }
    scope :alphabetical, -> { order(:name) }

    # Methods
    def asset_count
      assets.not_deleted.count
    end

    def normalized_name
      name.downcase.strip
    end

    def similar_tags
      Dam::Tag.where(tenant: tenant).where("name ILIKE ?", "%#{name}%").where.not(id: id).limit(5)
    end

    def to_param
      name.parameterize
    end

    private

    def bump_asset_list_cache_version
      return if tenant_id.blank?

      key = "dam:assets:list:v1:tenant:#{tenant_id}:ver"
      Rails.cache.increment(key, 1, initial: 1)
    rescue => e
      Rails.logger.warn "Failed to bump asset list cache version for tenant #{tenant_id}: #{e.message}"
    end

    def ensure_tenant_is_set
      if tenant_id.blank? && Dam.current_tenant.present?
        self.tenant = Dam.current_tenant
        self.tenant_id = Dam.current_tenant.id
      end
    end
  end
end
