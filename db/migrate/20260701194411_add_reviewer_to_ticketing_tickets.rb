class AddReviewerToTicketingTickets < ActiveRecord::Migration[8.1]
  def up
    add_reference :ticketing_tickets, :reviewer, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
    # I ticket già aperti prendono reviewer = reporter (auto-fill retroattivo, coerente col create).
    execute "UPDATE ticketing_tickets SET reviewer_id = reporter_id WHERE reviewer_id IS NULL"
  end

  def down
    remove_reference :ticketing_tickets, :reviewer, foreign_key: { to_table: :accounts }
  end
end
