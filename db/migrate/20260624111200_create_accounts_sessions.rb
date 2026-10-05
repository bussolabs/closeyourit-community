class CreateAccountsSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts_sessions, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts }, index: true

      t.string :ip_address
      t.string :user_agent
    end
  end
end
