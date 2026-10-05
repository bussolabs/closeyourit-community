class CreateSharedSecrets < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_shared_variables, id: :uuid do |t|
      t.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :name, null: false
      t.string :description, null: false, default: ""
      t.timestamps
    end
    add_index :secrets_shared_variables, %i[organization_id name], unique: true

    create_table :secrets_shared_values, id: :uuid do |t|
      t.references :shared_variable, null: false, type: :uuid,
                   foreign_key: { to_table: :secrets_shared_variables, on_delete: :cascade }
      t.references :environment, null: false, type: :uuid, foreign_key: { to_table: :types_environments, on_delete: :restrict }
      t.text :value, null: false
      t.integer :version_number, null: false, default: 0
      t.timestamps
    end
    add_index :secrets_shared_values, %i[shared_variable_id environment_id], unique: true, name: "idx_shared_values_identity"

    create_table :secrets_shared_versions, id: :uuid do |t|
      t.references :shared_value, null: false, type: :uuid,
                   foreign_key: { to_table: :secrets_shared_values, on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.integer :number, null: false
      t.text :value, null: false
      t.timestamps
    end
    add_index :secrets_shared_versions, %i[shared_value_id number], unique: true

    create_table :secrets_shared_delegations, id: :uuid do |t|
      t.references :shared_value, null: false, type: :uuid,
                   foreign_key: { to_table: :secrets_shared_values, on_delete: :cascade }
      t.references :project, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :secrets_shared_delegations, %i[shared_value_id project_id], unique: true, name: "idx_shared_delegations_identity"

    create_table :secrets_shared_events, id: :uuid do |t|
      t.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :shared_variable, type: :uuid,
                   foreign_key: { to_table: :secrets_shared_variables, on_delete: :nullify }
      t.references :environment, type: :uuid, foreign_key: { to_table: :types_environments, on_delete: :nullify }
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :actor, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :action, null: false
      t.string :name, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :secrets_shared_events, %i[organization_id created_at]
  end
end
