require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"

Bundler.require(*Rails.groups)
require "dam"

# Minimal host app for the DAM engine's specs: its own Tenant and User models, a token
# authenticated API base controller, and the DAM mounted at /api/v1.
module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.api_only = true
    config.autoload_lib(ignore: %w[assets tasks])
    config.active_job.queue_adapter = :test
    config.active_storage.service = :test
  end
end
