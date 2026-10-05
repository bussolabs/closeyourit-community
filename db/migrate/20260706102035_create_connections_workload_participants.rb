class CreateConnectionsWorkloadParticipants < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_workload_participants, id: :uuid do |t|
      t.timestamps

      t.references :action, type: :uuid, null: false,
                   foreign_key: { to_table: :workload_actions, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }

      t.index %i[action_id account_id], unique: true,
              name: "index_workload_participants_on_action_and_account"
    end
  end
end
