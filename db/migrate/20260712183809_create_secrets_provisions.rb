class CreateSecretsProvisions < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_provisions, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts }
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_project, type: :uuid, null: false,
                                    foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :destination_project, type: :uuid, null: false,
                                         foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :source_environment, type: :uuid, null: false,
                                        foreign_key: { to_table: :types_environments, on_delete: :restrict }
      t.references :destination_environment, type: :uuid, null: false,
                                             foreign_key: { to_table: :types_environments, on_delete: :restrict }
      t.references :token, type: :uuid, null: false,
                           foreign_key: { to_table: :projects_tokens, on_delete: :cascade }
      t.references :secret_variable, type: :uuid, null: false,
                                     foreign_key: { to_table: :secrets_variables, on_delete: :cascade }

      t.integer :status, null: false, default: 0
      t.string :idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.string :secret_name, null: false
      t.boolean :sync_github, null: false, default: true
      t.string :error_code
      t.string :error_message
      t.datetime :synced_at
    end

    add_index :secrets_provisions, %i[organization_id idempotency_key], unique: true
  end
end
