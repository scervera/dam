module Dam
  class AssetTag < ApplicationRecord
    self.table_name = "asset_tags"

    belongs_to :asset, class_name: "Dam::Asset"
    belongs_to :tag, class_name: "Dam::Tag"
    belongs_to :tenant, class_name: Dam.tenant_class_name

    # Callbacks
    before_validation :ensure_tenant_is_set
    after_commit :bump_asset_list_cache_version, on: [ :create, :update, :destroy ]

    validates :tenant_id, presence: true

    private

    def bump_asset_list_cache_version
      return if tenant_id.blank?

      key = "dam:assets:list:v1:tenant:#{tenant_id}:ver"
      Rails.cache.increment(key, 1, initial: 1)
    rescue => e
      Rails.logger.warn "Failed to bump asset list cache version for tenant #{tenant_id}: #{e.message}"
    end

    def ensure_tenant_is_set
      if tenant_id.blank?
        # Try to get tenant from asset first, then tag, then Current
        if asset&.tenant_id.present?
          self.tenant_id = asset.tenant_id
        elsif tag&.tenant_id.present?
          self.tenant_id = tag.tenant_id
        elsif Dam.current_tenant.present?
          self.tenant = Dam.current_tenant
          self.tenant_id = Dam.current_tenant.id
        end
      end
    end
  end
end
