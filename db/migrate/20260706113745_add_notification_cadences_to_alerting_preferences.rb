class AddNotificationCadencesToAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    # Cadenza per singola notifica × canale: mappa event_type => "immediate"/"daily"/"weekly"/"off".
    # Chiave assente → default di catalogo (Notifications::Catalog). Sostituisce i toggle grossolani
    # per-sorgente (errors_enabled/… restano per il backfill, non più letti).
    add_column :alerting_preferences, :email_cadences, :jsonb, null: false, default: {}
    add_column :alerting_preferences, :telegram_cadences, :jsonb, null: false, default: {}

    # Interruttore globale del canale Telegram per questa coppia (account, org). L'email ha già
    # email_enabled; l'in-app è sempre attivo (non disattivabile). Telegram parte spento.
    add_column :alerting_preferences, :telegram_enabled, :boolean, null: false, default: false
  end
end
