# frozen_string_literal: true

# Lista di todo personale, per-organizzazione (come Ticketing::SavedView): appartiene a un account
# dentro un'org. on_delete cascade: muore con l'account e con l'org. L'unicità è (account,
# organization, name); position abilita il riordino manuale. La condivisione in lettura vive in
# todos_shares (join separato), non qui.
class CreateTodosLists < ActiveRecord::Migration[8.1]
  def change
    create_table :todos_lists, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string  :name, null: false
      t.string  :color
      t.integer :position, null: false, default: 0
    end

    add_index :todos_lists, %i[account_id organization_id name], unique: true
    add_index :todos_lists, %i[account_id organization_id position]
  end
end
