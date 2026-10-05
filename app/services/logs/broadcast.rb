# frozen_string_literal: true

module Logs
  # Page-refresh Turbo realtime dello stream log dell'org (CYRA-57, gemello di Errors::Broadcast/CYRA-41).
  # Contratto write-side del PATH CALDO d'ingest: un burst di log (flush a 1000 dalla gemma, o un errore
  # che logga in loop) arrivava a Logs::Ingest::Record che renderizzava un partial + scriveva su Action
  # Cable PER OGNI riga inserita (fino a 1000 render+cable per batch) → il worker :ingest restava bloccato
  # secondi per batch, con backpressure sull'intera coda. Qui invece un SOLO segnale di refresh
  # (action="refresh") per batch: niente HTML, niente render nel worker. Ogni viewer ri-fetcha la PROPRIA
  # index (coi suoi filtri level/environment/project/range e la paginazione) e morpha — così il refresh
  # applica anche i filtri live, che il vecchio prepend org-wide ignorava. SEMPRE invocato DOPO il commit
  # dell'insert_all. Throttle LEADING + TRAILING (Solid Cache + Realtime::BroadcastRefreshJob): leading
  # immediato al primo evento della finestra, trailing coalescato a fine burst per mostrare lo stato
  # FINALE. Il nome-stream viene SOLO da Realtime::Streams → isolamento tenant (org:<id>:) nel nome.
  module Broadcast
    module_function

    # Refresh (leading + trailing coalescato) sulla lista log, su DUE livelli (CYRA-822):
    # l'organizzazione, per chi guarda tutto, e i progetti del batch, per chi sta guardando solo
    # quelli. Un batch di log appartiene a un progetto solo, quindi il segnale sa già di chi è: chi
    # sta guardando un altro progetto non ri-chiede più la propria lista per righe che non vedrà.
    # `projects` vuoto = solo il livello org-wide, cioè il comportamento di sempre.
    def refresh(organization, projects: [])
      Realtime::ThrottledRefresh.call(Realtime::Streams.logs(organization))
      Array(projects).uniq.each do |project|
        Realtime::ThrottledRefresh.call(Realtime::Streams.project_logs_list(project))
      end
    end
  end
end
