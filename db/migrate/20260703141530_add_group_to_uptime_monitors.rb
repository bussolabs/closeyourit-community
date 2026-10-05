# frozen_string_literal: true

# Un monitor appartiene (opzionalmente) a un Uptime::Group. Cancellando il gruppo il monitor
# sopravvive "senza gruppo" (nullify). group_id è MUTABILE (a differenza di project/environment,
# immutabili dopo la creazione).
class AddGroupToUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    add_reference :uptime_monitors, :group, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :uptime_groups, on_delete: :nullify }
  end
end
