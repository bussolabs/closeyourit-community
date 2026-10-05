# frozen_string_literal: true

module Uptime
  # Pinga un singolo monitor e ne registra l'esito. Solo monitor attivi; se sparito/pausato → no-op.
  class CheckJob < ApplicationJob
    queue_as :uptime

    # Un solo check alla volta per monitor: il dispatcher ri-accoda ogni minuto e last_checked_at è
    # scritto solo a fine RecordCheck, quindi un ping lento (>60s) lascia il monitor «due» e ne
    # accoderebbe un secondo in parallelo → due incident aperti (CYRA-269). L'indice unique è il
    # backstop DB; questo evita la race a monte. Monitor diversi restano paralleli.
    limits_concurrency to: 1, key: ->(monitor_id) { "uptime:check:#{monitor_id}" }

    def perform(monitor_id)
      monitor = Uptime::Monitor.active.find_by(id: monitor_id)
      return if monitor.nil?

      result = Uptime::Ping.call(monitor: monitor)
      Uptime::RecordCheck.call(monitor: monitor, result: result)
    end
  end
end
