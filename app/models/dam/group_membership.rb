module Dam
  class GroupMembership < ApplicationRecord
    self.table_name = "group_memberships"

    belongs_to :group, class_name: "Dam::Group"
    belongs_to :user, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name

    validates :user_id, uniqueness: { scope: [ :group_id, :tenant_id ] }
    validates :role, inclusion: { in: %w[member admin] }
    validates :tenant_id, presence: true

    scope :admins, -> { where(role: "admin") }
    scope :members, -> { where(role: "member") }
  end
end
