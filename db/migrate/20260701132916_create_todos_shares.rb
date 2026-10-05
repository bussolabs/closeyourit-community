# frozen_string_literal: true

# Condivisione in sola lettura di UNA lista con UN membro dell'organizzazione (il destinatario).
# on_delete cascade su entrambi i lati: la condivisione cade con la lista o con l'account destinatario.
# Unicità (list, account): non si condivide due volte con lo stesso membro. Il vincolo "destinatario
# membro dell'org della lista" e "non sé stesso" è nel model (Todos::Share).
class CreateTodosShares < ActiveRecord::Migration[8.1]
  def change
    create_table :todos_shares, id: :uuid do |t|
      t.timestamps

      t.references :list, type: :uuid, null: false,
                   foreign_key: { to_table: :todos_lists, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
    end

    add_index :todos_shares, %i[list_id account_id], unique: true
  end
end
