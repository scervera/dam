module Dam
  class SmartFolder < ApplicationRecord
    self.table_name = "smart_folders"

    belongs_to :user, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name
    belongs_to :group, required: false, class_name: "Dam::Group"

    # Validations
    validates :name, presence: true, length: { maximum: 255 }, uniqueness: { scope: :tenant_id, case_sensitive: false }
    validates :tag_criteria, presence: true
    validates :sort_order, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :visibility_level, inclusion: { in: %w[personal group global] }
    validates :match_logic, inclusion: { in: %w[any all] }
    validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/, message: "must be a valid hex color" }, allow_blank: true
    validates :tenant_id, presence: true

    # Scopes
    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:sort_order, :name) }
    scope :for_user, ->(user) { where(user: user) }
    scope :pinned, -> { where(pinned_to_sidebar: true) }
    scope :visible_to, ->(user) {
      tenant = Dam.current_tenant
      unless tenant
        accessible_tenants = user.respond_to?(:accessible_tenants) ? user.accessible_tenants : Dam.tenant_class.none
        tenant = accessible_tenants.first
      end
      base_scope = tenant ? where(tenant: tenant) : all

      group_folder_ids = base_scope.where(visibility_level: "group")
        .joins(:group)
        .merge(Dam::Group.for_user(user))
        .pluck(:id)

      base_scope.where(visibility_level: "global")
        .or(base_scope.where(user: user))
        .or(base_scope.where(id: group_folder_ids))
        .or(base_scope.where("shared_user_ids LIKE ?", "%\"#{user.id}\"%"))
    }

    # Callbacks
    before_validation :ensure_tenant_is_set
    before_validation :set_default_sort_order, on: :create

    # Instance methods
    def tag_names
      return [] if tag_criteria.blank?
      tag_criteria.split(",").map(&:strip).reject(&:blank?)
    end

    def tag_names=(tag_names)
      self.tag_criteria = tag_names.is_a?(Array) ? tag_names.join(", ") : tag_names
    end

    def has_tags?
      tag_names.any?
    end

    def shared_user_ids_array
      return [] if shared_user_ids.blank?
      JSON.parse(shared_user_ids) rescue []
    end

    def shared_user_ids_array=(ids)
      self.shared_user_ids = ids.to_json
    end

    def add_shared_user(user_id)
      ids = shared_user_ids_array
      ids << user_id unless ids.include?(user_id)
      self.shared_user_ids_array = ids
    end

    def remove_shared_user(user_id)
      ids = shared_user_ids_array
      ids.delete(user_id)
      self.shared_user_ids_array = ids
    end

    def visible_to?(user)
      return true if visibility_level == "global"
      return true if self.user_id == user.id
      return true if visibility_level == "group" && group && group.member?(user)
      return true if shared_user_ids_array.include?(user.id)
      false
    end

    def asset_count(viewing_user = nil)
      return 0 unless has_tags?
      assets_query(viewing_user).count
    end

    def assets(viewing_user = nil)
      return ::Dam::Asset.none unless has_tags?
      assets_query(viewing_user).order(created_at: :desc)
    end

    def matches_asset?(asset)
      return false unless has_tags?

      asset_tags = asset.tag_names

      if match_logic == "all"
        tag_names.all? { |tag| asset_tags.include?(tag) }
      else
        tag_names.any? { |tag| asset_tags.include?(tag) }
      end
    end

    private

    def assets_query(viewing_user)
      base_query = ::Dam::Asset.where(tenant: tenant).joins(:tags).where(tags: { name: tag_names, tenant: tenant }).distinct

      if match_logic == "all"
        tag_names.each do |tag_name|
          base_query = base_query.where(
            id: ::Dam::Asset.where(tenant: tenant).joins(:tags).where(tags: { name: tag_name, tenant: tenant }).select(:id)
          )
        end
      end

      if viewing_user
        base_query = base_query.where(
          "assets.visibility_level = ? OR assets.user_id = ?",
          ::Dam::Asset.visibility_levels[:org_wide],
          viewing_user.id
        )
      end

      base_query
    end

    def set_default_sort_order
      self.sort_order ||= (user.smart_folders.maximum(:sort_order) || 0) + 1
    end

    def ensure_tenant_is_set
      if tenant_id.blank? && Dam.current_tenant
        self.tenant_id = Dam.current_tenant.id
        self.tenant = Dam.current_tenant
      end
    end
  end
end
