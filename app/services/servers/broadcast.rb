# frozen_string_literal: true

module Servers
  # Broadcast Turbo realtime della fleet server. Centralizza target/partial condivisi dai call-site
  # (ingest in Servers::Ingest::Record, staleness in Servers::CheckStaleJob, azioni del controller
  # Member), così il contratto write-side vive in un solo posto. SEMPRE invocato DOPO il commit.
  # I nomi-stream vengono SOLO da Realtime::Streams → isolamento tenant (org:<id>:) implicito nel nome.
  module Broadcast
    module_function

    # Stream servers dell'org (fleet index): replace della riga host (target dom_id(host)) con lo
    # snapshot fresco. Solo replace (no append): gli host nuovi compaiono al reload — convenzione
    # condivisa con errors/metrics (la lista è filtrata/paginata per-viewer lato server).
    def row(host)
      # CYRA-458: passa le soglie effettive dell'host così la riga aggiornata live conserva il limite
      # accanto ai valori (senza attendere un reload). Un host per broadcast → il set org è per lui solo.
      thresholds = Alerting::ServerThresholds.for(host.organization).for_host(host)
      # CYRA-465 — la riga aggiornata live deve avere le STESSE colonne dell'header: la cella
      # temperatura c'è solo se la flotta la riporta (flag org-level, O(1) con l'indice parziale),
      # altrimenti una riga con una cella in più romperebbe l'allineamento dopo un push.
      temp_column = ::Servers::Sample.temperature_reported?(host.organization)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.servers(host.organization_id),
        target: ActionView::RecordIdentifier.dom_id(host),
        partial: "member/monitoring/servers/host_row",
        locals: { host: host, thresholds: thresholds, temp_column: temp_column }
      )
    end

    # Replace delle pill header (target servers_stats). Conteggi org-wide: lo stream è condiviso
    # dall'org e il broadcast non ha contesto per-viewer — per i server non c'è discrepanza (risorsa
    # org-level: chi vede la fleet la vede tutta). Un solo GROUP BY status (Prosopite-safe).
    def stats(organization_id)
      by_status = Servers::Host.where(organization_id: organization_id).group(:status).count
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.servers(organization_id),
        target: "servers_stats",
        partial: "member/monitoring/servers/stats",
        locals: { up_count: by_status.fetch("up", 0), down_count: by_status.fetch("down", 0),
                  total: by_status.values.sum }
      )
    end

    # Stream dell'host (show): segnale di page-refresh Turbo 8. Non spedisce HTML: ogni viewer
    # ri-fetcha il PROPRIO URL (incluso ?range per-viewer) e morpha il DOM preservando lo scroll.
    # Così TUTTA la show diventa live (header status/uptime/agent + istogrammi + container + systemd +
    # SMART), superando il vincolo per-viewer che teneva gli istogrammi "fuori v1" (il broadcast non
    # conosceva params[:range]). La show opta al morph via turbo_refreshes_with (vedi show.html.erb).
    def refresh(host)
      Turbo::StreamsChannel.broadcast_refresh_to(Realtime::Streams.server_host(host))
    end
  end
end
