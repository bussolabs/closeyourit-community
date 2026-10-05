# frozen_string_literal: true

module Analytics
  # Broadcast Turbo realtime della dashboard web analytics (page-refresh Turbo 8). Invocato da
  # Analytics::Ingest::Record dopo l'insert dei pageview: ogni viewer della dashboard di QUEL
  # progetto ri-fetcha il PROPRIO URL (col suo range/environment/filtri) e morpha il DOM — così
  # header/grafico/tabelle/chip diventano live senza reload, superando il limite del vecchio polling
  # (che aggiornava solo il chip visitatori). Il nome-stream viene SOLO da Realtime::Streams
  # (isolamento tenant org:<id>: implicito nel nome). Pattern condiviso con Servers::Broadcast#refresh.
  module Broadcast
    module_function

    # Segnale di page-refresh Turbo sullo stream analytics del progetto. Non spedisce HTML.
    def refresh(project)
      return unless throttle_ok?(project)

      Turbo::StreamsChannel.broadcast_refresh_to(Realtime::Streams.analytics(project))
    end

    # Scrive la chiave solo se assente (ritorna true) → un solo refresh per finestra per progetto.
    # Solid Cache in produzione = throttle cross-process; in test (null_store) non blocca mai.
    def throttle_ok?(project)
      Rails.cache.write(
        "analytics:broadcast:#{project.id}", true,
        unless_exist: true, expires_in: Analytics::Constants::BROADCAST_THROTTLE
      )
    end
    private_class_method :throttle_ok?
  end
end
