class CreateCronsMonitors < ActiveRecord::Migration[8.1]
  def change
    create_table :crons_monitors, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :environment, type: :uuid, foreign_key: { to_table: :types_environments, on_delete: :nullify }

      t.string  :slug, null: false                    # identificatore stabile del job (dal client)
      t.string  :name, null: false
      t.integer :expected_interval_minutes, null: false  # cadenza attesa del check-in
      t.integer :grace_minutes, null: false, default: 5  # tolleranza prima di dichiararlo missed
      t.integer :status, null: false, default: 0         # 0 unknown / 1 ok / 2 late / 3 missed
      t.datetime :last_check_in_at
      t.datetime :missed_alerted_at                      # dedup alert missed
      t.boolean :enabled, null: false, default: true

      t.index %i[project_id slug], unique: true
      t.index %i[status enabled]
    end
  end
end
