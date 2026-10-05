# frozen_string_literal: true

module Errors
  # Broadcast Turbo realtime dei gruppi d'errore. Due contratti write-side, per profilo di volume:
  #  - INGEST (path caldo, Errors::Ingest::Record) → `refresh`: page-refresh Turbo 8, NON ricalcola stats
  #    org-wide (il vecchio `group` = group(:status).count su tutti i gruppi dell'org saturava la coda
  #    :ingest sotto burst → CYRA-41). Ogni viewer ri-fetcha e morpha. Throttle LEADING + TRAILING per
  #    stream (Solid Cache + Realtime::BroadcastRefreshJob): leading immediato al primo evento della
  #    finestra, trailing coalescato a fine burst per mostrare lo stato FINALE (un leading-edge puro
  #    lascerebbe la UI ferma all'inizio del burst).
  #  - TRIAGE (basso volume, azione utente nel controller Member) → `group`: replace chirurgico della
  #    riga (target per-record) + lo stesso refresh per le pill.
  # SEMPRE invocato DOPO il commit. I nomi-stream vengono SOLO da Realtime::Streams. Il prefisso
  # `org:<id>:` isola fra tenant, non fra progetti dentro l'org: per questo su uno stream org-wide
  # può viaggiare solo un segnale di refresh o un replace per-record — mai aggregati renderizzati
  # (CYRA-257, vedi il commento di Realtime::Streams).
  module Broadcast
    module_function

    # Ingest: i due stream toccati da una nuova occorrenza — lista org (errors) e show del gruppo
    # (error_group). Solo un segnale di refresh (action="refresh"): niente HTML, niente aggregati org-wide.
    def refresh(group)
      refresh_list(group.project.organization, projects: [ group.project ])
      refresh_group(group)
    end

    # Refresh (leading + trailing coalescato) sulla lista, su DUE livelli (CYRA-822): quello
    # dell'organizzazione, per chi guarda tutto, e quello dei progetti toccati, per chi sta
    # guardando solo quelli. Emettere su entrambi costa un broadcast in più per evento e risparmia
    # una GET completa per ogni sessione che stava guardando un altro progetto — che sotto raffica
    # è l'unico costo che cresce col numero di sessioni connesse.
    #
    # `projects` vuoto significa "non so quali progetti sono toccati": resta il solo livello
    # org-wide, cioè il comportamento di sempre. Meglio un segnale in più che una lista ferma.
    def refresh_list(organization, projects: [])
      Realtime::ThrottledRefresh.call(Realtime::Streams.errors(organization))
      Array(projects).uniq.each do |project|
        Realtime::ThrottledRefresh.call(Realtime::Streams.project_errors_list(project))
      end
    end

    # Refresh (leading + trailing coalescato) sullo stream della singola show.
    def refresh_group(group)
      Realtime::ThrottledRefresh.call(Realtime::Streams.error_group(group))
    end

    # Replace della riga gruppo sullo stream PER-PROGETTO (non org-wide): il target è per-record, ma
    # l'HTML renderizzato arriverebbe comunque sul wire a chi il progetto non lo vede (titolo/culprit
    # dell'errore), anche se nel DOM è no-op (CYRA-271). Più il page-refresh org-wide per le pill.
    #
    # Le stats NON si spediscono più renderizzate: erano conteggi org-wide su target fisso
    # (`errors_stats`, presente in ogni pagina errori), quindi un membro che vede due progetti
    # leggeva i totali dell'intera organizzazione (CYRA-257). Il refresh throttlato fa ri-fetchare
    # a ogni viewer la lista con la propria sessione, che le ri-rende sui SUOI progetti — ed è già
    # il meccanismo che l'ingest usa nel path caldo (refresh_list).
    def group(group)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.project_errors(group.project), target: ActionView::RecordIdentifier.dom_id(group),
        partial: "member/monitoring/error_groups/group_row", locals: { group: group }
      )
      refresh_list(group.project.organization, projects: [ group.project ])
    end
  end
end
