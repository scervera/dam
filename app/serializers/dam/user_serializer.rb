module Dam
  # A user as referenced by DAM resources: a collection's owner and a group's members
  # (GroupSerializer embeds members in "included"). Only exposes what the DAM needs
  # from the host's user model.
  class UserSerializer
    include JSONAPI::Serializer

    set_type :user

    attributes :email
  end
end
