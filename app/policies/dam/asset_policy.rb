module Dam
  class AssetPolicy < Dam::ApplicationPolicy
    class Scope < Scope
      def resolve
        return scope.none unless user

        # Soft-deleted assets are excluded for every role, admins included.
        # They are reachable only through the recycle bin actions
        # (recycle_bin, restore, purge), which look records up without this scope.
        scope.not_deleted
      end
    end

    def show?
      user.admin? || can_view?
    end

    def create?
      user.admin? || user.tenant_owner? || user.dam_writer?
    end

    def update?
      return true if user.admin?
      return true if user.tenant_owner?
      record.user_id == user.id
    end

    def destroy?
      return true if user.admin?
      return true if user.tenant_owner?
      record.user_id == user.id
    end

    def tag?
      user.admin? || user.tenant_owner? || user.dam_writer?
    end

    def download?
      show?
    end

    def generate_poster_frame?
      # Same permissions as update - must be admin or owner
      update?
    end

    def derivatives?
      show?
    end

    def lineage?
      show?
    end

    private

    def can_view?
      # Until visibility fields are added, allow all authenticated users to view
      true
    end
  end
end
