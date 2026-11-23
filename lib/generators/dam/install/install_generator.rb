require "rails/generators"
require "rails/generators/active_record"

module Dam
  module Generators
    # bin/rails generate dam:install [--tenant-table=tenants] [--user-table=users]
    #
    # Adds a migration that creates the DAM tables (PostgreSQL) and an initializer to
    # connect the DAM to the app's tenants, users and authentication.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :tenant_table, type: :string, default: "tenants",
                                  desc: "Table holding your tenants (DAM rows reference it as tenant_id)"
      class_option :user_table, type: :string, default: "users",
                                desc: "Table holding your users (referenced as user_id, owner_id, uploaded_by_id)"

      def create_migration_file
        migration_template "create_dam_tables.rb.tt", File.join(db_migrate_path, "create_dam_tables.rb")
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/dam.rb"
      end

      def show_next_steps
        say <<~TEXT

          Next:
            1. bin/rails db:migrate
            2. Mount the API inside your API scope in config/routes.rb, e.g.
                 scope "api/v1" do mount Dam::Engine, at: "/" end
            3. Fill in config/initializers/dam.rb (parent controller, current tenant/user).
        TEXT
      end

      private

      def tenant_table = options[:tenant_table]
      def user_table = options[:user_table]
    end
  end
end
