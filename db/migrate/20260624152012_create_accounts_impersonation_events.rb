class CreateAccountsImpersonationEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts_impersonation_events, id: :uuid do |t|
      t.timestamps

      t.references :god, type: :uuid, null: false, foreign_key: { to_table: :accounts }
      t.references :account, type: :uuid, null: false, foreign_key: { to_table: :accounts }

      t.datetime :started_at, null: false
      t.datetime :ended_at,   null: true
    end
  end
end
