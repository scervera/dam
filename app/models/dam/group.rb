module Dam
  class Group < ApplicationRecord
    belongs_to :owner, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name
    has_many :group_memberships, class_name: "Dam::GroupMembership", dependent: :destroy
    has_many :members, through: :group_memberships, source: :user, class_name: Dam.user_class_name
    has_many :smart_folders, class_name: "Dam::SmartFolder", dependent: :nullify

    validates :name, presence: true, length: { maximum: 255 }
    validates :name, uniqueness: { scope: [ :owner_id, :tenant_id ] }
    validates :tenant_id, presence: true

    scope :active, -> { where(active: true) }
    scope :for_user, ->(user) {
      joins(:group_memberships).where(group_memberships: { user_id: user.id })
    }

    def add_member(user, role: "member")
      group_memberships.find_or_create_by(user: user, tenant: tenant) do |membership|
        membership.role = role
      end
    end

    def remove_member(user)
      group_memberships.where(user: user).destroy_all
    end

    def member?(user)
      members.include?(user)
    end

    def admin?(user)
      group_memberships.where(user: user, role: "admin").exists?
    end
  end
end
