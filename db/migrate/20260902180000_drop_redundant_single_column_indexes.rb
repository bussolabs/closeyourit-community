# frozen_string_literal: true

# CYRA-749 — le tabelle scritte dall'ingest (occorrenze di errore, log, campioni di metrica, web
# vitals, campioni di server e di container) portavano un indice su UNA colonna sola quando esisteva
# già un indice composito che comincia con la stessa colonna. PostgreSQL usa il PREFISSO di un B-tree
# composito per una condizione sulla sola prima colonna, quindi il singolo non serviva a nessuna
# lettura: `WHERE project_id = $1` passa da [project_id, created_at] esattamente come passava da
# [project_id].
#
# Non serviva in lettura, ma si pagava in scrittura: un INSERT aggiorna TUTTI gli indici della
# tabella, e qui gli INSERT arrivano a raffica. Otto indici in meno sono otto aggiornamenti in meno
# per ogni riga che entra, più lo spazio e il lavoro di manutenzione che smettono di esistere.
#
# Restano al loro posto gli indici a colonna sola che un composito NON copre: `[recorded_at]` di
# servers_samples e servers_container_samples (nessun composito comincia con quella colonna, serve
# alla potatura per data trasversale agli host) e `[organization_id]` di servers_samples, il cui
# omonimo parziale `index_servers_samples_temp_reported` vede solo le righe con un sensore letto.
#
# Le chiavi esterne sono tutte ON DELETE CASCADE: la cancellazione del padre esegue
# `DELETE FROM figlio WHERE fk = $1`, che è a sua volta una condizione sulla prima colonna del
# composito — nessuna cancellazione diventa una scansione completa.
#
# CONCURRENTLY (+ disable_ddl_transaction!) perché un DROP INDEX normale prende un lock esclusivo
# sulla tabella: su queste, in produzione, vorrebbe dire fermare l'ingest per la durata del comando.
class DropRedundantSingleColumnIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # nome dell'indice da togliere => [tabella, colonne del composito che lo copre]
  REDUNDANT_INDEXES = {
    "index_errors_events_on_group_id" => [ :errors_events, :group_id ],
    "index_errors_events_on_project_id" => [ :errors_events, :project_id ],
    "index_logs_entries_on_project_id" => [ :logs_entries, :project_id ],
    "index_metrics_samples_on_group_id" => [ :metrics_samples, :group_id ],
    "index_metrics_samples_on_project_id" => [ :metrics_samples, :project_id ],
    "index_analytics_web_vitals_on_project_id" => [ :analytics_web_vitals, :project_id ],
    "index_servers_samples_on_host_id" => [ :servers_samples, :host_id ],
    "index_servers_container_samples_on_host_id" => [ :servers_container_samples, :host_id ]
  }.freeze

  def up
    REDUNDANT_INDEXES.each do |name, (table, _column)|
      # if_exists perché la migration deve poter ripartire: senza transazione, un DROP CONCURRENTLY
      # interrotto lascia rimossi quelli già fatti.
      remove_index table, name: name, algorithm: :concurrently, if_exists: true
    end
  end

  def down
    REDUNDANT_INDEXES.each do |name, (table, column)|
      add_index table, column, name: name, algorithm: :concurrently, if_not_exists: true
    end
  end
end
