class CreateCronsCheckIns < ActiveRecord::Migration[8.1]
  def change
    create_table :crons_check_ins, id: :uuid do |t|
      t.datetime :created_at, null: false

      t.references :monitor, type: :uuid, null: false, foreign_key: { to_table: :crons_monitors, on_delete: :cascade }

      t.integer :status, null: false, default: 0   # esito riportato dal job: 0 ok / 1 fail
      t.integer :duration_ms
      t.datetime :checked_in_at, null: false

      t.index %i[monitor_id checked_in_at]
    end
  end
end
