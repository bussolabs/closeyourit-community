# frozen_string_literal: true

module Realtime
  # Emette un page-refresh Turbo (action="refresh") su uno stream, DIFFERITO di una finestra di throttle.
  # È il ramo TRAILING del throttle di Metrics::Broadcast / Errors::Broadcast (CYRA-41): il primo evento
  # di una finestra fa il refresh leading (immediato); gli eventi successivi coalescono in QUESTO job,
  # schedulato una sola volta per stream per finestra, che a fine burst mostra lo stato FINALE — così un
  # throttle leading-edge puro non lascia la UI ferma all'inizio del burst. Il payload è la sola String
  # dello stream (da Realtime::Streams, tenant-prefissata): niente record da deserializzare, il refresh è
  # idempotente (ritentarlo è innocuo).
  class BroadcastRefreshJob < ApplicationJob
    queue_as :ingest

    # `frame` (CYRA-823, opzionale) restringe il segnale a un solo pezzo di pagina. Resta una String
    # come lo stream — niente record da deserializzare — e i job già in coda senza di essa continuano
    # a girare come prima.
    def perform(stream, frame = nil)
      Realtime::ThrottledRefresh.broadcast(stream, frame)
    ensure
      # Rilascia il lock trailing: da qui in poi il prossimo evento del burst può accodare il
      # PROSSIMO job per questo stream — e uno solo. Nell'`ensure` perché un lock non rilasciato per
      # un broadcast fallito congelerebbe gli aggiornamenti dello stream fino alla scadenza del TTL.
      Rails.cache.delete(Realtime::ThrottledRefresh.tail_key(stream))
      Ops::LocalGate.release(Realtime::ThrottledRefresh.tail_key(stream))
    end
  end
end
