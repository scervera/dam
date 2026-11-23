module Dam
  # Default per-request store for the current tenant and user. Hosts that already have
  # their own point Dam.config.current_tenant / current_user at it instead.
  class Current < ActiveSupport::CurrentAttributes
    attribute :tenant, :user
  end
end
