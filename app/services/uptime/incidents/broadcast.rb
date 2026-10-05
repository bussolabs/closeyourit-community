# frozen_string_literal: true

module Uptime
  module Incidents
    # Broadcast Turbo della lista incident di un monitor (replace del target stabile
    # `monitor_incidents_<id>`). Fonte UNICA: usato da RecordCheck (apertura/chiusura macchina) e dai
    # service umani (grouping, update, ungroup) così member vede sempre lo stato aggiornato in tempo reale.
    module Broadcast
      module_function

      def incidents(monitor)
        Turbo::StreamsChannel.broadcast_replace_to(
          Realtime::Streams.monitor(monitor),
          target: "monitor_incidents_#{monitor.id}",
          partial: "member/monitoring/monitors/incidents",
          locals: { monitor: monitor }
        )
      rescue StandardError => e
        # Il broadcast è una nicety realtime: NON deve mai far fallire il chiamante. Girando dopo la
        # mutazione (es. Ungroup fa update_all POI broadcast), una sua eccezione — render o, tipico,
        # write su Solid Cable (SQLite) sotto contention dai broadcast continui di check/server —
        # 500-erebbe una richiesta il cui effetto è GIÀ committato (gruppo diviso ma 500 all'utente).
        # Log e prosegui: il member riallinea al prossimo reload/broadcast.
        Rails.logger.error("Uptime::Incidents::Broadcast.incidents failed monitor=#{monitor.id}: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
