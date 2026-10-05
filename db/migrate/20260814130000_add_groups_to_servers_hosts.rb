# frozen_string_literal: true

# CYRA-470 — i gruppi (etichette libere) con cui organizzare la flotta: "produzione", "staging", "CI".
# Un array jsonb come le altre liste dell'host (ignored_container_patterns, failed_services): pochi
# valori brevi per macchina, letti insieme allo snapshot nella fleet index (nessuna tabella a parte).
# Default [] NOT NULL: una macchina senza gruppi ha una lista vuota, mai NULL — filtro e conteggio non
# devono distinguere due "assenze".
class AddGroupsToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :groups, :jsonb, default: [], null: false
  end
end
