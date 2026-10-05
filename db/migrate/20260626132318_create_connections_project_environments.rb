class CreateConnectionsProjectEnvironments < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_project_environments, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments }

      t.index %i[project_id environment_id], unique: true
    end
  end
end
