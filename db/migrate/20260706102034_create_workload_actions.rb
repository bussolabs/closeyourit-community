class CreateWorkloadActions < ActiveRecord::Migration[8.1]
  def change
    create_table :workload_actions, id: :uuid do |t|
      t.timestamps

      t.references :team, type: :uuid, null: false,
                   foreign_key: { to_table: :teams_teams, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :ticket, type: :uuid, null: true,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }

      t.string   :title,        null: false
      t.text     :description
      t.integer  :status,       null: false, default: 0
      t.datetime :scheduled_at, null: true
      t.datetime :due_at,       null: true
      t.datetime :completed_at, null: true

      t.index %i[team_id status]
      t.index :scheduled_at
    end
  end
end
