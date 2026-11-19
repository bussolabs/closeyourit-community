# frozen_string_literal: true

class AddDownAlertedAtToServersHostsAndClusters < ActiveRecord::Migration[8.1]
  # CYRA-1228 — il segno «avviso di fermo affidato alla coda», scritto DOPO l'accodamento.
  #
  # Server e cluster passavano a down e poi accodavano l'avviso: se il processo cadeva in quel varco,
  # il controllo successivo non li guardava più (giudica solo chi è ancora up) e l'avviso era perso
  # per sempre. Con questa colonna la riga stessa dice cosa deve ancora partire: down + nil = da
  # consegnare. Il recupero (Alerting::ReconcileOutages) legge di qui; per i lavori pianificati il
  # segno esiste già (crons_monitors.missed_alerted_at).
  #
  # Il pregresso si marca come già annunciato: senza, il primo giro di recupero spedirebbe un avviso
  # per ogni macchina, cluster o lavoro già fermo al momento del rilascio.
  def up
    add_column :servers_hosts, :down_alerted_at, :datetime
    add_column :clusters_clusters, :down_alerted_at, :datetime

    execute "UPDATE servers_hosts SET down_alerted_at = now() WHERE status = 2"
    execute "UPDATE clusters_clusters SET down_alerted_at = now() WHERE status = 2"
    execute "UPDATE crons_monitors SET missed_alerted_at = now() WHERE status = 3 AND missed_alerted_at IS NULL"

    # Indici PARZIALI: interrogano solo i pendenti, che nel funzionamento normale sono zero.
    add_index :servers_hosts, :last_push_at, where: "status = 2 AND down_alerted_at IS NULL",
              name: "index_servers_hosts_pending_down_alert"
    add_index :clusters_clusters, :last_snapshot_at, where: "status = 2 AND down_alerted_at IS NULL",
              name: "index_clusters_clusters_pending_down_alert"
    add_index :crons_monitors, :last_check_in_at, where: "status = 3 AND missed_alerted_at IS NULL",
              name: "index_crons_monitors_pending_missed_alert"
  end

  # Il segno scritto sui lavori pianificati resta: è la stessa colonna di prima, e valorizzata dice
  # il vero (quell'avviso era già partito con il codice precedente).
  def down
    remove_index :crons_monitors, name: "index_crons_monitors_pending_missed_alert"
    remove_index :clusters_clusters, name: "index_clusters_clusters_pending_down_alert"
    remove_index :servers_hosts, name: "index_servers_hosts_pending_down_alert"
    remove_column :clusters_clusters, :down_alerted_at
    remove_column :servers_hosts, :down_alerted_at
  end
end
