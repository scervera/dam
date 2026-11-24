module Dam
  class DropZone < ApplicationRecord
    belongs_to :owner, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name
    has_many :drop_zone_files, class_name: "Dam::DropZoneFile", dependent: :destroy
    has_many :assets, through: :drop_zone_files, class_name: "Dam::Asset"
    has_many :drop_zone_subscriptions, class_name: "Dam::DropZoneSubscription", dependent: :destroy
    has_many :subscribers, through: :drop_zone_subscriptions, source: :user, class_name: Dam.user_class_name

    validates :name, presence: true, length: { maximum: 255 }
    validates :description, length: { maximum: 1000 }
    validates :tenant_id, presence: true

    # JSON attributes
    serialize :preset_tags, coder: JSON
    serialize :settings, coder: JSON
    serialize :accepted_file_types, coder: JSON

    scope :active, -> { where(is_active: true) }
    scope :owned_by, ->(user) { where(owner: user) }

    before_validation :ensure_tenant_is_set
    before_validation :ensure_preset_tags_is_array
    before_validation :ensure_accepted_file_types_is_array

    def preset_tag_names
      preset_tags || []
    end

    def preset_tag_names=(tag_names)
      self.preset_tags = Array(tag_names).compact.uniq
    end

    def settings_hash
      settings || {}
    end

    def settings_hash=(hash)
      self.settings = hash.is_a?(Hash) ? hash : {}
    end

    def recent_files(limit = 10)
      drop_zone_files.includes(:asset, :uploaded_by).order(uploaded_at: :desc).limit(limit)
    end

    def file_count
      drop_zone_files.count
    end

    def subscriber_count
      drop_zone_subscriptions.count
    end

    def can_be_accessed_by?(user)
      return false unless user
      # Compare by ID for reliability (works even if association isn't loaded)
      return true if owner_id == user.id
      drop_zone_subscriptions.exists?(user_id: user.id)
    end

    def subscribe_user!(user, notification_preferences = {})
      subscription = drop_zone_subscriptions.find_or_initialize_by(user: user)
      subscription.notification_preferences = notification_preferences
      subscription.subscribed_at = Time.current
      subscription.save!
      subscription
    end

    def unsubscribe_user!(user)
      drop_zone_subscriptions.where(user: user).destroy_all
    end

    def notify_subscribers_of_new_file(file, uploaded_by)
      Rails.logger.info "New file uploaded to Drop Zone '#{name}' by #{uploaded_by.email}: #{file.asset.filename}"
    end

    def accepted_file_types_array
      accepted_file_types || [ "image", "video", "audio", "document" ]
    end

    def accepted_file_types_array=(types)
      self.accepted_file_types = Array(types).compact.uniq
    end

    def accepts_file_type?(asset_type)
      accepted_file_types_array.include?(asset_type.to_s)
    end

    private

    def ensure_tenant_is_set
      return if tenant_id.present?

      if Dam.current_tenant
        self.tenant = Dam.current_tenant
      elsif tenant_id.nil? && Dam.current_tenant&.id
        self.tenant_id = Dam.current_tenant.id
      end
    end

    def ensure_preset_tags_is_array
      self.preset_tags = [] if preset_tags.nil?
    end

    def ensure_accepted_file_types_is_array
      self.accepted_file_types = [ "image", "video", "audio", "document" ] if accepted_file_types.nil?
    end
  end
end
