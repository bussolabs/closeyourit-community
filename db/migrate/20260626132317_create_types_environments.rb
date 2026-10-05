class CreateTypesEnvironments < ActiveRecord::Migration[8.1]
  def change
    create_table :types_environments, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }

      t.references :organization, type: :uuid, null: false, foreign_key: true

      t.string  :code, null: false                 # machine-readable (production/staging/development…)
      t.string  :label, null: false
      t.string  :color, null: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      t.index %i[organization_id code], unique: true
      t.index %i[organization_id active position]
    end
  end
end
