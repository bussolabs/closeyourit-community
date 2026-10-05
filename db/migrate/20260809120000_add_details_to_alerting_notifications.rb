# frozen_string_literal: true

class AddDetailsToAlertingNotifications < ActiveRecord::Migration[8.1]
  def change
    # Elenco completo dietro "mostra dettagli" (CYRA-323): il body ora porta conteggio+host, non la
    # lista intera (container caduti / servizi failed / dischi SMART). Nullable, nessun backfill: le
    # righe storiche restano senza dettagli espandibili, solo il body già congelato.
    add_column :alerting_notifications, :details, :jsonb
  end
end
