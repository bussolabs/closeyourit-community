# frozen_string_literal: true

# CYRA-151: il monitor uptime era HTTP-only e avvisava solo su down/up/ssl.
# - check_type: apre il monitor ad altri protocolli (tcp/porta, dns, ping) oltre a http.
# - host/port: bersaglio dei check non-http (url resta il bersaglio http).
# - latency_threshold_ms: soglia oltre cui un check UP ma lento genera un avviso (nil = disattivo).
# - latency_alerted_on: dedup giornaliero dell'avviso di lentezza (come ssl_alerted_on).
class AddCheckTypesAndLatencyToUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :uptime_monitors, :check_type, :integer, default: 0, null: false
    add_column :uptime_monitors, :host, :string
    add_column :uptime_monitors, :port, :integer
    add_column :uptime_monitors, :latency_threshold_ms, :integer
    add_column :uptime_monitors, :latency_alerted_on, :date

    # I check non-web non hanno una url: il bersaglio è host(+port). La presenza di url per i soli
    # monitor http resta garantita dalla validazione applicativa condizionale.
    change_column_null :uptime_monitors, :url, true
  end
end
