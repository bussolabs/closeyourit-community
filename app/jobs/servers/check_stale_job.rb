# frozen_string_literal: true

module Servers
  # Rilevazione host silenti (i dati sono PUSH: nessun polling): ogni minuto marca down gli host up
  # senza push da oltre SERVERS_STALE_AFTER_SECONDS e avvisa (server_down). Il recovery (down→up)
  # lo fa l'ingest al primo push utile.
  class CheckStaleJob < ApplicationJob
    queue_as :servers

    def perform
      # CYRA-775 — prima di leggere il silenzio come un guasto: il silenzio è nostro? Le
      # organizzazioni alle cui sonde il backend ha risposto «troppe richieste» dentro la finestra
      # escono dal giudizio di questo giro — il loro push non è mai arrivato per colpa NOSTRA e le
      # macchine possono stare benissimo. Le altre organizzazioni sono giudicate come sempre: un
      # rifiuto riguarda chi l'ha ricevuto, non tutta l'installazione.
      suspended_org_ids = Servers::IngestRejections.organization_ids
      notify_ingest_rejected(suspended_org_ids)

      touched_org_ids = []
      stale_hosts(suspended_org_ids).find_each do |host|
        host.update!(status: :down)
        Alerting::EvaluateJob.perform_later(
          event_type: "server_down", subject_type: "Servers::Host", subject_id: host.id,
          project_id: nil, organization_id: host.organization_id
        )
        # Il down deve arrivare live a chi guarda fleet/show: replace riga fleet + page-refresh show per host...
        Servers::Broadcast.row(host)
        Servers::Broadcast.refresh(host)
        touched_org_ids << host.organization_id
      end
      # ...ma le pill una sola volta per org (N host down = 1 GROUP BY, non N).
      touched_org_ids.uniq.each { |org_id| Servers::Broadcast.stats(org_id) }

      notify_silent_hosts(suspended_org_ids)
    end

    private

    # Il rifiuto è un segnale PROPRIO, non un guasto travestito: chi aveva macchine sotto giudizio in
    # questo giro riceve un avviso che dice che i dati sono stati respinti da noi. Uno per
    # organizzazione e non uno per macchina — la causa è una sola, e nell'episodio del 3 settembre la
    # forma «uno per macchina» ha prodotto quarantanove avvisi in otto minuti su ventidue host. Chi
    # non aveva niente sotto giudizio non riceve nulla: il rifiuto senza conseguenze resta nel log.
    # Nessuno stato cambia e nessun broadcast parte: non sappiamo niente di nuovo sulle macchine.
    def notify_ingest_rejected(suspended_org_ids)
      return if suspended_org_ids.empty?

      organization_ids = (Servers::Host.stale.where(organization_id: suspended_org_ids)
                                       .distinct.pluck(:organization_id) +
                          silent_host_candidates.where(organization_id: suspended_org_ids)
                                                .distinct.pluck(:organization_id)).uniq
      return if organization_ids.empty?

      Rails.logger.warn(
        "[servers] giudizio sospeso: il backend ha rifiutato le sonde " \
        "(organizzazioni=#{organization_ids.size})"
      )

      organization_ids.each do |organization_id|
        Alerting::EvaluateJob.perform_later(
          event_type: "server_ingest_rejected", subject_type: "Organizations::Organization",
          subject_id: organization_id, project_id: nil, organization_id: organization_id
        )
      end
    end

    # Le macchine da dichiarare giù: quelle silenziose delle organizzazioni che NON abbiamo rifiutato.
    def stale_hosts(suspended_org_ids)
      scope = Servers::Host.stale
      suspended_org_ids.empty? ? scope : scope.where.not(organization_id: suspended_org_ids)
    end

    # CYRA-676 — l'avviso che mancava per il caso descritto in Servers::Host#silent?: la macchina
    # risponde (last_push_at fresco, quindi NON finisce nel giro stale qui sopra) ma il dato mostrato
    # è fermo da oltre la soglia d'allarme. Scatta UNA volta per silenzio (silent_alerted_at fa da
    # memoria; l'ingest la azzera al primo dato fresco). La soglia larga da 15' evita di rifare i
    # falsi allarmi di CYRA-649 quando la corsia dei dati è semplicemente in arretrato di qualche
    # minuto.
    def notify_silent_hosts(suspended_org_ids)
      now = Time.current
      candidates = silent_host_candidates(now:)
      candidates = candidates.where.not(organization_id: suspended_org_ids) if suspended_org_ids.any?
      candidates.find_each do |host|
        host.update!(silent_alerted_at: now)
        Alerting::EvaluateJob.perform_later(
          event_type: "server_silent", subject_type: "Servers::Host", subject_id: host.id,
          project_id: nil, organization_id: host.organization_id
        )
      end
    end

    def silent_host_candidates(now: Time.current)
      Servers::Host.active.status_up
                   .where(silent_alerted_at: nil)
                   .where(last_push_at: (now - Servers::Constants::STALE_AFTER_SECONDS.seconds)..)
                   .where(last_seen_at: ...now - Servers::Constants::SILENT_ALERT_AFTER_SECONDS.seconds)
    end
  end
end
