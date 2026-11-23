class CreateTenantsAndUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :tenants do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :users do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :email, null: false
      t.string :role, null: false, default: "writer"
      t.string :api_token, null: false, index: { unique: true }
      t.datetime :disabled_at
      t.timestamps
    end
  end
end
