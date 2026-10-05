# frozen_string_literal: true

# CYRA-678 — gemello di ignored_container_patterns per le unit systemd: una unit rumorosa (oneshot
# che fallisce per design, servizio di terzi che flappa) oggi costringe a spegnere la regola
# server_service_failed per tutta la macchina. I frammenti per-host escludono la unit dagli avvisi
# senza toccare lo stato raccolto.
class AddIgnoredServicePatternsToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :ignored_service_patterns, :jsonb, default: [], null: false
  end
end
