module Dam
  # Settings a host application uses to plug the DAM into its own tenants, users,
  # authentication and storage. Set them in an initializer:
  #
  #   Dam.configure do |config|
  #     config.tenant_class = "Account"
  #     config.parent_controller = "Api::BaseController"
  #     config.current_tenant = -> { Current.account }
  #   end
  #
  # Model classes and the parent controller are read when DAM classes load, so set them
  # in an initializer, before any Dam model or controller is referenced.
  #
  # Side effects the host may care about are published as ActiveSupport::Notifications
  # events instead of settings (see Dam.instrument):
  #   "asset_created.dam"     payload { asset: }  after an asset is created and committed
  #   "asset_destroying.dam"  payload { asset: }  before an asset row is deleted; remove
  #                                               rows that reference it (errors abort)
  #   "ai_usage.dam"          payload { tenant:, input_tokens:, output_tokens: }
  class Configuration
    # Class names (strings) of the host's tenant and user models.
    attr_accessor :tenant_class, :user_class

    # Class name of the controller Dam::Api::V1::BaseController inherits. It must provide
    # authenticate_user! (a before_action), current_user, tenant_scope(relation),
    # render_success(data, status) and render_error(message, status), and should respond
    # to Pundit::NotAuthorizedError (e.g. 403).
    attr_accessor :parent_controller

    # Read and set the current tenant and user (callables). The setters receive the new
    # value (or nil); jobs set the tenant while they work and clear it afterwards.
    attr_accessor :current_tenant, :set_current_tenant, :current_user, :set_current_user

    # ->(token) { user or nil }. Used by GET /assets/:id/stream, which accepts a token in
    # the query string because <video> elements cannot send an Authorization header.
    attr_accessor :authenticate_token

    # ->(user, request) { tenant or nil }: the tenant a token-authenticated stream request
    # acts in. Must only return a tenant the user belongs to; nil responds 404.
    attr_accessor :tenant_for_request

    # ->(tenant, user_id) { user }: finds a user who belongs to the tenant (adding group
    # members). Raise ActiveRecord::RecordNotFound when there is none.
    attr_accessor :find_tenant_user

    # ->(tenant) { user or nil }: who owns files a watched folder imports for the tenant.
    attr_accessor :import_user_for

    # -> { true/false }: soft-delete assets to a recycle bin instead of destroying them.
    attr_accessor :soft_delete_enabled
    # -> { Integer }: days a soft-deleted asset stays in the recycle bin.
    attr_accessor :asset_retention_days
    # ->(kind) { service name or nil }: Active Storage service for generated files
    # (kind is "derivative"); nil uses the default service.
    attr_accessor :storage_service_for

    # ->(user) { Hash } and ->(tenant) { Hash }: how an asset's user and tenant appear in
    # asset responses.
    attr_accessor :serialize_user, :serialize_tenant

    # -> { String }: prefix of the per-tenant AWS Rekognition face collections
    # ("<prefix>-tenant-<id>").
    attr_accessor :face_collection_prefix

    # ->(&request) { request.call }: wraps every AI request, e.g. for rate limiting.
    attr_accessor :ai_request_wrapper
    # Exception classes (or names) raised by ai_request_wrapper that are worth retrying.
    attr_accessor :ai_retryable_errors

    def initialize
      @tenant_class = "Tenant"
      @user_class = "User"
      @parent_controller = "ActionController::API"
      @current_tenant = -> { Dam::Current.tenant }
      @set_current_tenant = ->(tenant) { Dam::Current.tenant = tenant }
      @current_user = -> { Dam::Current.user }
      @set_current_user = ->(user) { Dam::Current.user = user }
      @authenticate_token = ->(_token) { nil }
      @tenant_for_request = ->(user, _request) { user.try(:tenant) }
      @find_tenant_user = ->(tenant, user_id) { tenant.users.find(user_id) }
      @import_user_for = ->(tenant) { tenant.users.first }
      @soft_delete_enabled = -> { false }
      @asset_retention_days = -> { 30 }
      @storage_service_for = ->(_kind) { nil }
      @serialize_user = ->(user) { { id: user.id } }
      @serialize_tenant = ->(tenant) { { id: tenant.id } }
      @face_collection_prefix = -> { ENV.fetch("AWS_REKOGNITION_COLLECTION_ID", "dam-faces") }
      @ai_request_wrapper = ->(&request) { request.call }
      @ai_retryable_errors = []
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def tenant_class_name = config.tenant_class.to_s
    def user_class_name = config.user_class.to_s
    def tenant_class = tenant_class_name.constantize
    def user_class = user_class_name.constantize

    def current_tenant = config.current_tenant.call
    def current_user = config.current_user.call

    def current_tenant=(tenant)
      config.set_current_tenant.call(tenant)
    end

    def current_user=(user)
      config.set_current_user.call(user)
    end

    # Publishes a DAM event ("#{name}.dam") to ActiveSupport::Notifications subscribers.
    def instrument(name, payload = {}, &block)
      ActiveSupport::Notifications.instrument("#{name}.dam", payload, &block)
    end
  end
end
