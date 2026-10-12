# frozen_string_literal: true

# A paused machine finishes the work it holds and takes no new one. `paused_until` ends the pause by itself.
class AddPauseToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    change_table :agents_hosts, bulk: true do |t|
      t.datetime :paused_at
      t.datetime :paused_until
      t.string :pause_reason
      t.references :paused_by, type: :uuid, null: true,
                               foreign_key: { to_table: :accounts, on_delete: :nullify }
    end
  end
end
