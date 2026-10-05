# frozen_string_literal: true

# Vista salvata sull'index ticket: un set di filtri (kind/status/priority/assignee/project/q) nominato,
# personale e per-organizzazione. on_delete cascade: muore con l'account e con l'org. L'unicità è
# (account, organization, name); la sua prefissa serve anche lo scope .for(account, organization).
class CreateTicketingSavedViews < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_saved_views, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string :name, null: false
      t.jsonb :filters, null: false, default: {}
    end

    add_index :ticketing_saved_views, %i[account_id organization_id name], unique: true
  end
end
