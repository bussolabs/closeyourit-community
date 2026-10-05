class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }

      t.string :name, null: false
      t.string :slug, null: false

      t.index :slug, unique: true
    end
  end
end
