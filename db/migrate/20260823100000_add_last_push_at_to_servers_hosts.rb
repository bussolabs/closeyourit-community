# frozen_string_literal: true

# CYRA-649 — separa "quando la macchina ha parlato" da "a che ora è la fotografia che ha mandato".
# last_seen_at vale recorded_at (orologio dell'agent) e lo scrive l'ingest ASINCRONO: misurando la
# salute su quello, un arretrato nella corsia dei dati faceva sembrare giù tutta la flotta.
# last_push_at lo scrive il controller nel momento in cui la richiesta entra.
#
# Backfill dai valori esistenti: senza, ogni host nascerebbe con NULL e resterebbe fuori dallo scope
# `stale` fino al primo push (fino a 60s di cecità) oppure obbligherebbe a una COALESCE permanente.
class AddLastPushAtToServersHosts < ActiveRecord::Migration[8.1]
  def up
    add_column :servers_hosts, :last_push_at, :datetime
    add_index :servers_hosts, [ :status, :last_push_at ]
    execute "UPDATE servers_hosts SET last_push_at = last_seen_at WHERE last_seen_at IS NOT NULL"
  end

  def down
    remove_index :servers_hosts, [ :status, :last_push_at ]
    remove_column :servers_hosts, :last_push_at
  end
end
