# Implements what the DAM expects from a host's user model.
class User < ApplicationRecord
  ROLES = %w[owner admin writer viewer].freeze

  belongs_to :tenant
  has_many :assets, class_name: "Dam::Asset"
  has_many :collections, class_name: "Dam::Collection"
  has_many :smart_folders, class_name: "Dam::SmartFolder"
  has_many :owned_groups, class_name: "Dam::Group", foreign_key: :owner_id
  has_many :owned_drop_zones, class_name: "Dam::DropZone", foreign_key: :owner_id
  has_many :drop_zone_subscriptions, class_name: "Dam::DropZoneSubscription"
  has_many :subscribed_drop_zones, through: :drop_zone_subscriptions, source: :drop_zone

  validates :role, inclusion: { in: ROLES }

  def admin?(*) = role == "admin"
  def tenant_owner?(*) = role == "owner"
  def dam_writer?(*) = role.in?(%w[owner admin writer])
  def disabled? = disabled_at.present?
end
