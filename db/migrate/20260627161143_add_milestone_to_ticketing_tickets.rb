class AddMilestoneToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    # milestone opzionale; alla cancellazione della milestone i ticket restano (milestone_id → null).
    add_reference :ticketing_tickets, :milestone, type: :uuid, null: true,
                  foreign_key: { to_table: :projects_milestones, on_delete: :nullify }
  end
end
