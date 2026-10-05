class AddSslAndKeywordChecksToUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    change_table :uptime_monitors, bulk: true do |t|
      # nil = check scadenza certificato disattivo; N = avvisa quando mancano <= N giorni.
      t.integer :ssl_expiry_warn_days
      # keyword attesa nel body (solo GET/POST): assente => check failed.
      t.string :expected_body_keyword
      # not_after dell'ultimo certificato osservato (aggiornato ad ogni ping https).
      t.datetime :ssl_expires_at
      # dedup alert scadenza: al massimo una notifica al giorno per monitor.
      t.date :ssl_alerted_on
    end
  end
end
