module Dam
  # JSON:API serializer for Dam::Group (/api/v1/groups). Pass include: [:members] to
  # embed the members as "included" user records (the groups page reads their email).
  class GroupSerializer
    include JSONAPI::Serializer

    set_type :group

    attributes :name, :description, :active, :created_at, :updated_at, :owner_id

    attribute :member_count do |group|
      group.members.count
    end

    has_many :members, serializer: Dam::UserSerializer
  end
end
