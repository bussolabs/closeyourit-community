class AddReviewGateToTypesTicketStatuses < ActiveRecord::Migration[8.1]
  def up
    add_column :types_ticket_statuses, :review_gate, :boolean, null: false, default: false
    # Allinea le org esistenti: lo status "In Review" è il gate di revisione di default.
    execute "UPDATE types_ticket_statuses SET review_gate = true WHERE code = 'in_review'"
  end

  def down
    remove_column :types_ticket_statuses, :review_gate
  end
end
