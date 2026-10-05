class CreateTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_tickets, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :reporter, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts }
      t.references :assignee, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :status, type: :uuid, null: false,
                   foreign_key: { to_table: :types_ticket_statuses }
      t.references :priority, type: :uuid, null: false,
                   foreign_key: { to_table: :types_ticket_priorities }

      t.integer :number, null: false
      t.string  :title,  null: false
      t.text    :description

      t.index [ :project_id, :number ], unique: true
    end
  end
end
