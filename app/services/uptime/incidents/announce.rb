# frozen_string_literal: true

module Uptime
  module Incidents
    # CYRA-792 — affida alla coda l'avviso di un incident e ne segna la consegna. Punto UNICO: lo
    # chiamano sia il controllo che ha appena registrato il cambio di stato (Uptime::RecordCheck) sia
    # il giro di recupero (Uptime::ReconcileAlerts), e la regola di «una volta sola» deve essere la
    # stessa per entrambi.
    #
    # Due precauzioni, e servono tutte e due:
    #
    #   1. il segno si scrive DOPO l'accodamento — scritto prima, un accodamento fallito lascerebbe
    #      l'avviso perso per sempre, che è il difetto da cui nasce questa classe;
    #   2. accodamento e segno stanno sotto lock, con rilettura della riga — il controllo successivo e
    #      il giro di recupero girano su worker diversi e possono avere in mano la stessa riga
    #      pendente nello stesso istante. Chi arriva secondo trova il segno e non accoda niente. Senza
    #      il lock i due avvisi partirebbero davvero, e la deduplicazione a valle
    #      (Alerting::Evaluate) li fonde solo se cadono nella stessa finestra di throttle: a cavallo
    #      di due finestre arriverebbero due notifiche per lo stesso disservizio.
    #
    # Un accodamento che fallisce fa rollback del segno: la riga torna pendente e il recupero riprova.
    class Announce < ApplicationService
      # Evento → colonna che ne registra la consegna. La coppia sta scritta qui e in nessun altro
      # posto: due elenchi che divergono farebbero segnare l'avviso sbagliato.
      MARKS = { "uptime_down" => :down_alerted_at, "uptime_up" => :up_alerted_at }.freeze

      def initialize(incident:, event_type:, at: Time.current)
        @incident = incident
        @event_type = event_type.to_s
        @at = at
      end

      # true = accodato adesso, false = già annunciato da qualcun altro.
      def call
        mark = MARKS.fetch(@event_type)
        announced = false
        @incident.with_lock do
          next if @incident[mark].present?

          monitor = @incident.monitor
          Alerting::EvaluateJob.perform_later(
            event_type: @event_type, subject_type: "Uptime::Incident", subject_id: @incident.id,
            project_id: monitor.project_id, environment_id: monitor.environment_id
          )
          @incident.update!(mark => @at)
          announced = true
        end
        Result.ok(announced)
      end
    end
  end
end
