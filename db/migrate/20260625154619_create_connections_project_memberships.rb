class CreateConnectionsProjectMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_project_memberships, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true

      t.index [ :account_id, :project_id ], unique: true,
              name: "index_project_memberships_on_account_and_project"
    end
  end
end
