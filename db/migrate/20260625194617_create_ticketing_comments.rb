class CreateTicketingComments < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_comments, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets }
      t.references :author, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts }

      t.text :body, null: false
    end
  end
end
