# frozen_string_literal: true

# CYRA-458: soglia d'allarme PER-MACCHINA delle metriche di occupazione (cpu/mem/disco). Nullable: host
# senza override → vale la soglia della regola org (Alerting::ServerThresholds). Stessa precisione delle
# colonne snapshot (cpu_pct/mem_pct/disk_pct): percentuali 0–100.
class AddAlertThresholdsToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :cpu_threshold, :decimal, precision: 5, scale: 2
    add_column :servers_hosts, :mem_threshold, :decimal, precision: 5, scale: 2
    add_column :servers_hosts, :disk_threshold, :decimal, precision: 5, scale: 2
  end
end
