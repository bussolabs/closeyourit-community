# frozen_string_literal: true

module Metrics
  # Broadcast Turbo realtime dei gruppi-metrica (page-refresh Turbo 8). Invocato da Metrics::Ingest::Record
  # dopo il commit di ogni campione. NON spedisce HTML e NON ricalcola aggregati org-wide: emette solo il
  # segnale di refresh; ogni viewer connesso ri-fetcha il PROPRIO URL (filtri/paginazione/visibilità) e
  # morpha il DOM. Così la lista e la show restano live SENZA le due aggregazioni org-wide + tre broadcast
  # per campione del vecchio path caldo, che sotto burst saturavano la coda :ingest (CYRA-41).
  #
  # Throttle LEADING + TRAILING per stream, via Solid Cache (coalescing): il PRIMO campione di una finestra
  # fa il refresh leading immediato (immediatezza per l'evento isolato); i campioni successivi coalescono in
  # UN refresh trailing schedulato a fine finestra (Realtime::BroadcastRefreshJob), che mostra lo stato
  # FINALE del burst. Senza il trailing, un throttle leading-edge puro lascerebbe la UI ferma all'inizio del
  # burst finché non arriva un evento dopo la finestra. I nomi-stream vengono SOLO da Realtime::Streams →
  # isolamento tenant (org:<id>:) implicito nel nome.
  module Broadcast
    module_function

    # I due stream toccati da un nuovo campione: lista org (metrics) e show del gruppo (metric_group).
    def refresh(group)
      refresh_list(group.project.organization, projects: [ group.project ])
      refresh_group(group)
    end

    # Refresh (leading + trailing coalescato) sulla lista, su DUE livelli (CYRA-822): organizzazione
    # per chi guarda tutto, progetti toccati per chi guarda solo quelli — così un campione del
    # progetto B non fa più ri-chiedere la lista a chi sta guardando A. `projects` vuoto = solo il
    # livello org-wide, cioè il comportamento di sempre.
    def refresh_list(organization, projects: [])
      Realtime::ThrottledRefresh.call(Realtime::Streams.metrics(organization))
      Array(projects).uniq.each do |project|
        Realtime::ThrottledRefresh.call(Realtime::Streams.project_metrics_list(project))
      end
    end

    # Refresh (leading + trailing coalescato) sullo stream della singola show.
    def refresh_group(group)
      Realtime::ThrottledRefresh.call(Realtime::Streams.metric_group(group))
    end
  end
end
