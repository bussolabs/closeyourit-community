class AddAnimatedToTypesTicketStatuses < ActiveRecord::Migration[8.1]
  def change
    add_column :types_ticket_statuses, :animated, :boolean, null: false, default: false

    # Backfill: gli stati "in lavorazione" pulsano (pallino animato).
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE types_ticket_statuses
          SET animated = TRUE
          WHERE code IN ('in_progress', 'in_review')
        SQL
      end
    end
  end
end
