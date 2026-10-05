# frozen_string_literal: true

module Agents
  module Attempts
    # CYRA-212 Scenario 2 — "il sistema gira a vuoto": host attivi che macinano lavoro senza mai concluderne
    # uno con successo. Rileva la condizione per organizzazione e accoda l'allarme org-scoped `agents_stalled`.
    #
    # È il gemello attivo del recovery (MarkStale): là si riaprono le fasi interrotte perché il ticket rientri
    # in coda, qui si avvisa se, nonostante ciò, per la finestra non esce ALCUN risultato buono. Il segnale è
    # l'ASSENZA DI PROGRESSO, non la durata dei running: col TTL di 1h delle fasi un tentativo può essere ancora
    # legittimamente in volo, mentre uno chiuso senza successo (orfano potato da MarkStale, fallito, bocciato) è
    # lavoro sprecato. Org attiva + lavoro sprecato nella finestra + zero `approved` = gira a vuoto.
    #
    # Solo host ONLINE: il caso "macchina spenta a metà" è lo Scenario 1 (recovery) e il badge stalled già
    # esistente; qui contano le macchine che RISULTANO ATTIVE eppure non producono nulla. Idempotente:
    # l'anti-spam dell'alerting (throttle/dedup per regola) collassa i giri ripetuti in una notifica per finestra.
    class DetectStalled < ApplicationService
      # Esiti terminali di SPRECO del sistema: la lavorazione si è chiusa senza risultato buono e senza
      # una decisione umana. Restano fuori `approved` (progresso reale) e — deliberatamente — `cancelled` e
      # `rejected`, che sono esiti VOLONTARI (annullamento via Workflows::Cancel, rifiuto umano con
      # motivazione): dopo un'azione umana normale il sistema non "gira a vuoto", quindi non deve allarmare.
      # `review_failed` invece lo scrive il Deliver (review del lavoro consegnato fallita) ed è spreco
      # automatico; `stale` è l'orfano potato da MarkStale; `failed` è un fallimento tecnico.
      UNPRODUCTIVE_STATUSES = %w[stale failed review_failed].freeze

      def initialize(now: Time.current, window: Agents::Constants::STALL_WINDOW)
        @now = now
        @window = window
        @since = now - window
      end

      def call
        flagged = 0
        candidate_org_ids.each do |org_id|
          next unless host_online?(org_id)
          next if progressed?(org_id)

          Alerting::EvaluateJob.perform_later(
            event_type: "agents_stalled", subject_type: "Organizations::Organization",
            subject_id: org_id, project_id: nil, organization_id: org_id
          )
          flagged += 1
        end
        Result.ok(flagged)
      end

      private

      # Org che hanno macinato lavoro nella finestra senza successo: almeno un tentativo chiuso in uno stato
      # improduttivo. Senza questo segnale il sistema è semplicemente fermo/tranquillo, non "a vuoto".
      #
      # CONFINE (per scelta): l'ancora è un tentativo AVVIATO e poi chiuso male, non "coda con lavoro pronto
      # mai reclamato". Coprire quest'ultimo richiederebbe la readiness della coda con TUTTI i filtri di
      # eleggibilità/lease/deferral di Agents::TicketQueues::Next (autorità unica di "cosa è reclamabile"):
      # duplicarli qui, parzialmente, allarmerebbe sui ticket deliberatamente non-eleggibili — un falso
      # positivo peggiore del caso coperto. Il caso reale del ticket (lavorazioni claimate e poi bloccate)
      # passa comunque da qui, via lo `stale` che MarkStale produce.
      def candidate_org_ids
        Agents::Attempt.where(status: UNPRODUCTIVE_STATUSES, finished_at: @since..@now)
                       .distinct.pluck(:organization_id)
      end

      # Le macchine risultano attive? `heartbeat_online?` è per-riga (colonne, non SQL): le org hanno pochi
      # host, l'iterazione è accettabile.
      def host_online?(org_id)
        Agents::Host.active.where(organization_id: org_id).any? { |host| host.heartbeat_online?(now: @now) }
      end

      # C'è stato progresso reale nella finestra? Un solo tentativo `approved` basta a escludere lo stallo.
      def progressed?(org_id)
        Agents::Attempt.status_approved
                       .where(organization_id: org_id, finished_at: @since..@now)
                       .exists?
      end
    end
  end
end
