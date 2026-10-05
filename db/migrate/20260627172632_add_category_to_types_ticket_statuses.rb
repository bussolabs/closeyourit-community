class AddCategoryToTypesTicketStatuses < ActiveRecord::Migration[8.1]
  # Categoria del flusso di lavoro (enum: open/in_progress/done) — serve a sapere quali status
  # contano come "completati" per il progress delle milestone. Default open; backfill per code.
  def up
    add_column :types_ticket_statuses, :category, :integer, null: false, default: 0
    execute("UPDATE types_ticket_statuses SET category = 1 WHERE code IN ('in_progress', 'in_review')")
    execute("UPDATE types_ticket_statuses SET category = 2 WHERE code IN ('resolved', 'closed')")
  end

  def down
    remove_column :types_ticket_statuses, :category
  end
end
