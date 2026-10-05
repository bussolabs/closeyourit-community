class AddLastTicketNumberToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_ticket_number, :integer, null: false, default: 0
  end
end
