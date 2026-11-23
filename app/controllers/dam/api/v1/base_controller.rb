module Dam
  module Api
    module V1
      # Base class for the DAM JSON API. It inherits the host's API controller
      # (Dam.config.parent_controller), which supplies authentication, tenant scoping and
      # the render helpers; see Dam::Configuration#parent_controller for the contract.
      class BaseController < Dam.config.parent_controller.constantize
        include Pundit::Authorization

        private

        # Creating and changing DAM content: admins, tenant owners and DAM writers.
        def require_user_or_admin
          return if current_user.admin? || current_user.dam_writer? || current_user.tenant_owner?

          render_error("User, admin, or owner access required", :forbidden)
        end
      end
    end
  end
end
