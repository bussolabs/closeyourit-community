# frozen_string_literal: true

module Agents
  module Hosts
    # CYRA-450 — "una macchina è ferma": un host che non batte da oltre la soglia di allarme (offline + grazia)
    # genera un avviso PER-HOST (`agents_host_stale`) via Alerting, come qualunque altro controllo. Complemento
    # degli allarmi gemelli: DetectStalled (org gira a vuoto) e DetectFailingHosts (macchina che gira ma butta
    # via il lavoro) guardano chi LAVORA; questo guarda chi non risponde più.
    #
    # Sola lettura: rende visibile un degrado altrimenti silenzioso (metà della capacità produttiva spenta per
    # giorni senza che nulla lo faccia notare). La soglia è il pavimento di grazia contro il rumore da riavvii
    # brevi — vive in Agents::Host#heartbeat_stale?, unica autorità di "cosa è fermo". Idempotente: l'anti-spam
    # dell'alerting (throttle/dedup per regola e subject) collassa i giri ripetuti in una notifica.
    class DetectStale < ApplicationService
      # CYRA-520 — un'automazione ferma da giorni non deve produrre un avviso identico ogni ora. Nel
      # caso reale ne sono arrivati 49 in due giorni, tutti uguali: a quel punto non li legge più
      # nessuno, e il 50° — che poteva essere un'altra macchina — passa inosservato in mezzo.
      #
      # Il promemoria si dirada: subito, dopo un'ora, poi 3, 6, 12, e da lì una volta al giorno finché
      # la macchina non torna a battere. Due giorni fermi ora costano 7 avvisi invece di 49.
      REMINDER_HOURS = [ 0, 1, 3, 6, 12 ].freeze
      DAILY_AFTER_HOURS = 24

      def initialize(now: Time.current)
        @now = now
      end

      def call
        flagged = 0
        # Solo host ATTIVI (non revocati): una macchina dismessa e ferma non è un allarme da riaprire. La
        # fleet è piccola e la soglia dipende dalle colonne interval+grace del singolo host → valutata in
        # Ruby (nessuno scope SQL), come già fa la lista /member/agents. Nessun N+1: tutto vive sulla riga.
        Agents::Host.active.find_each do |host|
          next unless host.heartbeat_stale?(now: @now)
          next unless reminder_due?(host)

          Alerting::EvaluateJob.perform_later(
            event_type: "agents_host_stale", subject_type: "Agents::Host",
            subject_id: host.id, project_id: nil, organization_id: host.organization_id
          )
          flagged += 1
        end
        Result.ok(flagged)
      end

      private

      # Un promemoria per gradino, indipendentemente da ogni quanto gira il controllo: il gradino è
      # "scoperto" se dal suo inizio non è ancora arrivato nessun avviso per questa macchina. Legare
      # la decisione al giro (ogni 15') la renderebbe fragile al primo cambio di cadenza.
      # `stale_since` non è mai nil qui: il chiamante l'ha già filtrato con `heartbeat_stale?`, che è
      # la stessa condizione. Una guardia in più sarebbe codice che non può girare.
      def reminder_due?(host)
        since = host.stale_since(now: @now)
        step_at = since + step_hours(((@now - since) / 1.hour).floor).hours
        !already_alerted_since?(host, step_at)
      end

      # Il gradino corrente: l'ultimo della scaletta già raggiunto, poi il giorno pieno più recente.
      def step_hours(elapsed)
        return (elapsed / DAILY_AFTER_HOURS) * DAILY_AFTER_HOURS if elapsed >= DAILY_AFTER_HOURS

        REMINDER_HOURS.reverse.find { |hours| elapsed >= hours } || 0
      end

      # Nessun avviso consegnato = nessuno da diradare: la prima segnalazione parte sempre.
      def already_alerted_since?(host, moment)
        Alerting::Notification
          .where(event_type: :agents_host_stale, subject_type: "Agents::Host", subject_id: host.id)
          .where(created_at: moment..).exists?
      end
    end
  end
end
