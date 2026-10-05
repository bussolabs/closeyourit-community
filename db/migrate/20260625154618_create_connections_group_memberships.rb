class CreateConnectionsGroupMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_group_memberships, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false, foreign_key: true
      t.references :group, type: :uuid, null: false,
                   foreign_key: { to_table: :projects_groups }

      t.index [ :account_id, :group_id ], unique: true,
              name: "index_group_memberships_on_account_and_group"
    end
  end
end
