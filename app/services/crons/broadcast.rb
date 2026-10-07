# frozen_string_literal: true

module Crons
  # Broadcast Turbo realtime dei cron monitor. Centralizza target/partial condivisi dai call-site
  # (check-in in Crons::RecordCheckIn, missed in Crons::EvaluateJob), così il contratto write-side
  # vive in un solo posto. SEMPRE invocato DOPO il commit. I nomi-stream vengono SOLO da
  # Realtime::Streams → isolamento tenant (org:<id>:) implicito nel nome.
  module Broadcast
    module_function

    # Project stream (list): replace of the monitor row (target dom_id(monitor)). Per project, not
    # org-wide: on the org stream the HTML reached viewers who cannot see the project (CYRA-1040).
    # Replace only (no append): monitors born at the first check-in appear on reload, the same
    # convention as errors/metrics/servers.
    def row(monitor)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.project_crons(monitor.project),
        target: ActionView::RecordIdentifier.dom_id(monitor),
        partial: "member/monitoring/cron_monitors/monitor_row", locals: { monitor: monitor }
      )
    end

    # Pill header: page-refresh throttlato, non più HTML renderizzato. Prima erano conteggi org-wide
    # su target fisso (`crons_stats`, presente in ogni pagina cron), quindi un membro che vede due
    # progetti leggeva i totali dell'intera organizzazione (CYRA-257). Col refresh ogni viewer
    # ri-fetcha la lista con la propria sessione e vede i PROPRI conteggi. Stessa convenzione di
    # errors/uptime.
    def stats(organization)
      Realtime::ThrottledRefresh.call(Realtime::Streams.crons(organization))
    end

    # Stream del monitor (show): prepend del nuovo check-in (target cron_monitor_check_ins_<id>).
    def check_in(monitor, check_in)
      Turbo::StreamsChannel.broadcast_prepend_to(
        Realtime::Streams.cron_monitor(monitor),
        target: "cron_monitor_check_ins_#{monitor.id}",
        partial: "member/monitoring/cron_monitors/check_in_row", locals: { check_in: check_in }
      )
    end

    # Stream del monitor (show): replace dell'header di stato (target cron_monitor_labels_<id>).
    def labels(monitor)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.cron_monitor(monitor),
        target: "cron_monitor_labels_#{monitor.id}",
        partial: "member/monitoring/cron_monitors/labels", locals: { monitor: monitor }
      )
    end
  end
end
