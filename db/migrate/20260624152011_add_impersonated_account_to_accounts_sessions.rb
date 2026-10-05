class AddImpersonatedAccountToAccountsSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :accounts_sessions, :impersonated_account, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts }
  end
end
