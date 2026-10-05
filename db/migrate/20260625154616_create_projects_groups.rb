class CreateProjectsGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_groups, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :organization, type: :uuid, null: false, foreign_key: true

      t.string :name,  null: false
      t.string :color

      t.index [ :organization_id, :name ]
    end
  end
end
