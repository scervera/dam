module Dam
  class DropZoneSubscription < ApplicationRecord
    self.table_name = "drop_zone_subscriptions"

    belongs_to :drop_zone, class_name: "Dam::DropZone"
    belongs_to :user, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name

    validates :subscribed_at, presence: true
    validates :user_id, uniqueness: { scope: :drop_zone_id, message: "is already subscribed to this drop zone" }
    validates :tenant_id, presence: true

    # JSON attributes
    serialize :notification_preferences, coder: JSON

    scope :active, -> { where.not(subscribed_at: nil) }
    scope :for_user, ->(user) { where(user: user) }
    scope :for_drop_zone, ->(drop_zone) { where(drop_zone: drop_zone) }

    def notification_preferences_hash
      notification_preferences || default_notification_preferences
    end

    def notification_preferences_hash=(hash)
      self.notification_preferences = hash.is_a?(Hash) ? hash : default_notification_preferences
    end

    def email_notifications_enabled?
      notification_preferences_hash["email"] == true
    end

    def in_app_notifications_enabled?
      notification_preferences_hash["in_app"] == true
    end

    def instant_notifications_enabled?
      notification_preferences_hash["instant"] == true
    end

    def digest_notifications_enabled?
      notification_preferences_hash["digest"] == true
    end

    def enable_email_notifications!
      prefs = notification_preferences_hash
      prefs["email"] = true
      self.notification_preferences = prefs
      save!
    end

    def disable_email_notifications!
      prefs = notification_preferences_hash
      prefs["email"] = false
      self.notification_preferences = prefs
      save!
    end

    def enable_in_app_notifications!
      prefs = notification_preferences_hash
      prefs["in_app"] = true
      self.notification_preferences = prefs
      save!
    end

    def disable_in_app_notifications!
      prefs = notification_preferences_hash
      prefs["in_app"] = false
      self.notification_preferences = prefs
      save!
    end

    private

    def default_notification_preferences
      {
        "email" => true,
        "in_app" => true,
        "instant" => true,
        "digest" => false
      }
    end
  end
end
