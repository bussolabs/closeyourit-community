# frozen_string_literal: true

# Unifica più finestre di downtime grezze in un incident logico "narrato":
# - parent_id: raggruppamento self-ref (un primary parent_id nil ha figli = le finestre unite).
# - phase: stato umano corrente della narrazione (nil = nessuna narrazione ancora).
# - title: titolo opzionale dell'incident narrato.
class AddGroupingAndPhaseToUptimeIncidents < ActiveRecord::Migration[8.1]
  def change
    add_reference :uptime_incidents, :parent, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :uptime_incidents, on_delete: :nullify }
    add_column :uptime_incidents, :phase, :integer, null: true
    add_column :uptime_incidents, :title, :string, null: true
  end
end
