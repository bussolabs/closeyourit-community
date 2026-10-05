# frozen_string_literal: true

# Generalizza le viste salvate oltre i ticket: rinomina la tabella, aggiunge il discriminatore
# `resource_type` (backfill "tickets" sulle righe esistenti) e sposta l'unicità del nome per risorsa.
class GeneralizeSavedViews < ActiveRecord::Migration[8.1]
  def change
    rename_table :ticketing_saved_views, :saved_views

    # Backfill le righe esistenti a "tickets", poi rimuove il default: il resource_type va sempre passato.
    add_column :saved_views, :resource_type, :string, null: false, default: "tickets"
    change_column_default :saved_views, :resource_type, from: "tickets", to: nil

    remove_index :saved_views, column: %i[account_id organization_id name], unique: true
    add_index :saved_views, %i[account_id organization_id resource_type name], unique: true
  end
end
