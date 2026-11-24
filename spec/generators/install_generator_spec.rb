require "rails_helper"
require "rails/generators"
require "generators/dam/install/install_generator"

RSpec.describe Dam::Generators::InstallGenerator do
  it "creates the tables migration and an initializer, honoring custom table names" do
    Dir.mktmpdir do |dir|
      Rails::Generators.invoke("dam:install", [ "--tenant-table=organizations", "--user-table=members", "--quiet" ],
                               destination_root: dir)

      migration = File.read(Dir[File.join(dir, "db/migrate/*_create_dam_tables.rb")].first)
      expect(migration.scan(/create_table "/).size).to eq(16)
      expect(migration).to include('add_foreign_key "dam_assets", "organizations", column: "tenant_id"')
      expect(migration).to include('add_foreign_key "dam_drop_zone_files", "members", column: "uploaded_by_id"')
      expect(migration).not_to include("force: :cascade")

      initializer = File.read(File.join(dir, "config/initializers/dam.rb"))
      expect(initializer).to include('config.tenant_class = "Organization"', 'config.user_class = "Member"')
    end
  end
end
