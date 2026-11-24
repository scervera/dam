ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Dir[File.join(__dir__, "support/**/*.rb")].each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include ActiveJob::TestHelper
  config.include DamSpecHelpers
  config.after { Dam::Current.reset }
  # Specs that call real AI provider APIs run only on request (see spec/live).
  config.filter_run_excluding :live unless ENV["DAM_LIVE_AI"] == "1"
end
