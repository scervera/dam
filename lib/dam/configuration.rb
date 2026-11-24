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
  #   "ai_usage.dam"          payload { tenant:, input_tokens:, output_tokens:, provider:,
  #                                     model: } after each AI request
  class Configuration
    DEFAULT_QUEUE_NAMES = {
      default: :default,       # thumbnails, derivatives, watched-folder scans
      ai: :default,            # auto-tagging and face detection
      purge: :default,         # recycle-bin purges
      scheduler: :default      # Dam::WatchedFolderSchedulerJob
    }.freeze

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

    # Active Job queue for each kind of DAM job; keys as in DEFAULT_QUEUE_NAMES. Missing
    # keys fall back to the defaults, so a host can set only the ones it changes:
    #   config.queue_names = { purge: :low_priority }
    attr_reader :queue_names

    # How Dam::WatchedFolderSchedulerJob repeats:
    #   :self_enqueue  each run enqueues the next one 30 seconds later (start it once, e.g.
    #                  from an initializer)
    #   :external      each run is a single pass; the host schedules it, e.g. a Solid Queue
    #                  recurring task or cron
    attr_accessor :watched_folder_scheduler

    # Directories watched folders may point into (strings). nil (the default) allows any
    # path the app can read; set it when users must not be able to import arbitrary server
    # files, e.g. config.watched_folder_roots = [ "/watched" ].
    attr_accessor :watched_folder_roots

    # false (default): watched folders are drop folders — each file is moved into the DAM
    # (deleted from the folder after import). true: originals are left in place (e.g. a
    # read-only NAS archive); files already imported are recognized by their path.
    attr_accessor :watched_folder_keep_originals

    # AI auto-tagging provider. nil (the default) builds one from ENV (DAM_AI_PROVIDER,
    # DAM_AI_MODEL, DAM_AI_API_KEY, DAM_AI_BASE_URL; see Dam::Ai::Providers.from_env).
    # Otherwise :openai, :openai_compatible or :anthropic (configured from ENV), or any
    # object that implements Dam::Ai::Providers::Base#analyze_image.
    attr_accessor :ai_provider

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
      @queue_names = DEFAULT_QUEUE_NAMES.dup
      @watched_folder_scheduler = :self_enqueue
      @watched_folder_keep_originals = false
      @ai_provider = nil
    end

    def queue_names=(names)
      @queue_names = DEFAULT_QUEUE_NAMES.merge(names.to_h.transform_keys(&:to_sym))
    end

    def queue_name(kind)
      queue_names.fetch(kind.to_sym)
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

    # True when AI auto-tagging is switched on and a provider is configured.
    def ai_tagging_enabled?
      ENV.fetch("DAM_AI_AUTO_TAG_ENABLED", "true").to_s.downcase.in?(%w[true 1 yes]) &&
        Dam::Ai::Providers.configured?
    end

    # True when face detection (AWS Rekognition) is switched on. Credentials come from
    # AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or the AWS default chain (e.g. an IAM role).
    def face_detection_enabled?
      ENV.fetch("DAM_FACE_DETECTION_ENABLED", "false").to_s.downcase.in?(%w[true 1 yes])
    end

    # Publishes a DAM event ("#{name}.dam") to ActiveSupport::Notifications subscribers.
    def instrument(name, payload = {}, &block)
      ActiveSupport::Notifications.instrument("#{name}.dam", payload, &block)
    end
  end
end
