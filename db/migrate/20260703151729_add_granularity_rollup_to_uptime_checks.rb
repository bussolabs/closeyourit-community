# frozen_string_literal: true

# Consolidamento rollup nella stessa tabella: `uptime_checks` diventa multi-granularità via
# discriminatore `granularity` (check=0 ping raw · hourly=1 · daily=2 aggregati). Le righe aggregate
# portano i contatori (checks_total/checks_up/avg_response_ms) + denorm incident sul daily
# (incidents_count/downtime_seconds). Il raw resta invariato nella semantica per-ping.
class AddGranularityRollupToUptimeChecks < ActiveRecord::Migration[8.1]
  def change
    change_table :uptime_checks, bulk: true do |t|
      t.integer  :granularity,      null: false, default: 0
      t.integer  :checks_total
      t.integer  :checks_up
      t.integer  :avg_response_ms
      t.integer  :incidents_count
      t.integer  :downtime_seconds
      t.datetime :updated_at
    end

    # Le righe aggregate non hanno un `up` singolo → `up` diventa nullable (validazione condizionata
    # a granularity=check nel model). Operazione catalog-only su Postgres, sicura a caldo.
    change_column_null :uptime_checks, :up, true

    # Il vecchio indice [monitor_id, checked_at] non discrimina raw/aggregati → sostituito con uno che
    # include `granularity` (tutte le query per sorgente filtrano granularity + checked_at).
    remove_index :uptime_checks, name: "index_uptime_checks_on_monitor_id_and_checked_at"
    add_index :uptime_checks, [ :monitor_id, :granularity, :checked_at ],
              name: "index_uptime_checks_on_monitor_granularity_checked_at"

    # Idempotenza upsert SOLO per gli aggregati (granularity <> 0): un bucket per [monitor, granularity,
    # bucket_at]. I ping raw (granularity=0) restano molti per lo stesso istante → esclusi dall'unicità.
    add_index :uptime_checks, [ :monitor_id, :granularity, :checked_at ],
              unique: true, where: "granularity <> 0", name: "index_uptime_rollups_unique"
  end
end
