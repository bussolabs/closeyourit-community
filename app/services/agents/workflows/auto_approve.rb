# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-868 — di decisione per ticket ne resta UNA: il piano.
    #
    # Ogni ticket lavorato dalla macchina ne chiedeva due, e la seconda arrivava quando i controlli
    # avevano già risposto: le decisioni si accumulavano e la consegna si fermava sempre lì. Il piano
    # è il punto in cui una persona decide COSA si fa; la consegna è già guardata da chi rilegge il
    # codice e dai controlli automatici, quindi con tutti i verdi passa da sola.
    #
    # Tre controlli, e servono tutti e tre — sono i tre modi diversi di sbagliarsi:
    #
    #   controlli automatici   il verbale del candidato dice `verified_passing` (CYRA-614)
    #   rilettura del codice   il tentativo che ha consegnato è accettato da chi l'ha riletto
    #   proposta ancora quella ApproveAutopilot riapre GitHub e confronta il codice vivo (CYRA-617)
    #
    # Manca un verde → non succede niente, e il lavoro resta davanti a una persona esattamente com'era:
    # la card mostra già il verbale col motivo, e i rami davvero rossi (controlli falliti, consegna
    # respinta) si fermano da soli molto prima di arrivare qui.
    class AutoApprove < ApplicationService
      def initialize(workflow:, candidate:, client: nil)
        @workflow = workflow
        @candidate = candidate
        @client = client
      end

      # Ok col workflow quando la consegna è avanzata da sola, ok con nil quando la decisione resta a
      # una persona. L'errore è solo quello di ApproveAutopilot, che chi chiama non propaga: «non è
      # passata da sola» non è un guasto della verifica appena fatta.
      def call
        return Result.ok(nil) unless all_green?

        outcome = ApproveAutopilot.call(workflow: @workflow, actor: nil, client: @client)
        return outcome if outcome.err?

        record_activity!
        Result.ok(@workflow)
      end

      private

      def all_green?
        @candidate.state_verified_passing? && review_accepted? && closer_pipeline?
      end

      # Il tentativo che ha consegnato questo codice, riletto e accettato. `status_approved?` non è
      # ridondante: un tentativo respinto conserva la review dichiarata dall'host, e guardare solo il
      # verdetto farebbe passare per accettata una consegna che il server aveva rifiutato.
      def review_accepted?
        attempt = @candidate.attempt
        attempt.present? && attempt.status_approved? && attempt.review_status_accepted?
      end

      # Senza una macchina che possa servire i closer, avanzare accoderebbe il ticket a una coda che
      # nessuno serve: lì la decisione umana serve ancora, perché è l'unica che può chiuderlo.
      def closer_pipeline?
        CloserPipeline.configured?(organization: @workflow.organization, project: @workflow.ticket.project)
      end

      # DoD — nella storia del ticket si deve vedere che il passaggio è stato automatico e SU QUALI
      # controlli. Senza i nomi, «è passato da solo» è una parola d'onore: una decisione che nessuno
      # ha preso va poter rimessa in discussione da chi la legge mesi dopo.
      #
      # Nessun attore, un nome di sistema: dietro questa riga c'era un programma, non una persona
      # (CYRA-406). Fuori dalla transazione di ApproveAutopilot, che ha già committato: nel caso
      # peggiore resta un'approvazione senza la sua riga, mai una riga senza l'approvazione.
      def record_activity!
        attempt = @candidate.attempt
        Ticketing::RecordActivity.call(
          ticket: @workflow.ticket, action: "autopilot_auto_approved",
          actor_name: I18n.t("member.tickets.activity.system.autopilot"),
          data: { checks: check_names, checks_count: @candidate.checks_count,
                  review: { status: attempt.review_status, runtime: attempt.reviewer_runtime } }
        )
      end

      # Il nome di ogni controllo verde. Le due forme non sono intercambiabili: un controllo moderno
      # si chiama `name`, uno storico `context`, e leggerne una sola lascerebbe la riga muta proprio
      # sui repository che usano l'altra.
      def check_names
        Array(@candidate.checks_payload).filter_map do |check|
          next unless check.is_a?(Hash)

          (check["name"].presence || check["context"].presence)
        end
      end
    end
  end
end
