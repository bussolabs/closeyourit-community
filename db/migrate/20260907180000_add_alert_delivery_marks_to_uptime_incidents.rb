# frozen_string_literal: true

class AddAlertDeliveryMarksToUptimeIncidents < ActiveRecord::Migration[8.1]
  # CYRA-792 — l'intento di avviso, scritto accanto al cambio di stato che lo genera.
  #
  # L'apertura e la chiusura di un incident vivevano solo in memoria: se l'accodamento dell'avviso
  # falliva subito dopo il commit, il controllo successivo trovava un incident già aperto (o già
  # risolto) e non ripeteva la transizione — l'avviso era perso per sempre. Con queste due colonne
  # l'incident stesso dice cosa deve ancora partire: nil = da consegnare, valorizzato = affidato alla
  # coda. Il recupero (Uptime::ReconcileAlerts) legge di qui.
  #
  # Il pregresso si marca come già annunciato: senza, il primo giro di recupero spedirebbe un avviso
  # per ogni disservizio mai registrato.
  def up
    add_column :uptime_incidents, :down_alerted_at, :datetime
    add_column :uptime_incidents, :up_alerted_at, :datetime

    execute <<~SQL.squish
      UPDATE uptime_incidents
         SET down_alerted_at = started_at,
             up_alerted_at = resolved_at
    SQL

    # Indici PARZIALI: interrogano solo i pendenti, che nel funzionamento normale sono zero — l'indice
    # resta minuscolo anche con una tabella di incident lunga anni.
    add_index :uptime_incidents, :started_at, where: "down_alerted_at IS NULL",
              name: "index_uptime_incidents_pending_down_alert"
    add_index :uptime_incidents, :resolved_at,
              where: "up_alerted_at IS NULL AND resolved_at IS NOT NULL",
              name: "index_uptime_incidents_pending_up_alert"
  end

  def down
    remove_index :uptime_incidents, name: "index_uptime_incidents_pending_up_alert"
    remove_index :uptime_incidents, name: "index_uptime_incidents_pending_down_alert"
    remove_column :uptime_incidents, :up_alerted_at
    remove_column :uptime_incidents, :down_alerted_at
  end
end
