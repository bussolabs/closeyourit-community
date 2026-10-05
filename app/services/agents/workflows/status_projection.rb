# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-622 — la parola sul ticket è la PROIEZIONE della fase della lavorazione, e la
    # corrispondenza fra le due vive qui: un posto solo.
    #
    # Prima ce n'erano due. La verifica del candidato mandava il ticket sul primo stato di revisione;
    # l'approvazione ne aveva una sua, «il primo stato di lavoro attivo non di revisione per
    # posizione». Finché di stati di lavoro ce n'era uno solo funzionava per caso: con le parole nuove
    # ce ne sono due — «In lavorazione» e «In chiusura» — e quella regola rimandava il ticket appena
    # approvato su «In lavorazione», la stessa parola che aveva PRIMA del sì. Chi guardava la bacheca
    # vedeva lavoro ancora da fare mentre il ticket stava già andando al rilascio.
    #
    # La destinazione non è mai un code fisso: ogni organizzazione nomina i suoi stati come vuole, e
    # un code scritto nel codice le romperebbe tutte. Si sceglie per semantica, fra gli stati che
    # l'organizzazione ha davvero.
    class StatusProjection < ApplicationService
      # `categoria` è quella che il cancello delle dipendenze deve proteggere: si legge dalla FASE,
      # senza toccare nessuna riga di stato, così un'organizzazione senza destinazione configurata non
      # può spegnere il cancello. `scelta` è come si trova la riga fra quelle dell'organizzazione.
      #
      # CYRA-623 — `fase_di_esecuzione` è il lavoro della macchina che PORTA a questa fase, e serve a
      # una cosa sola: sapere quale domanda fare ai prerequisiti senza scriverla una seconda volta. La
      # risposta la dà il cancello. Se qui si scrivesse una domanda propria, la coda potrebbe servire
      # un ticket che poi non riesce a muoversi — cioè il giro di macchina di nuovo buttato, che è
      # esattamente il guasto che si sta togliendo.
      Destination = Data.define(:category, :execution_phase, :picker)

      DESTINATIONS = {
        # Il sistema ha guardato la proposta: il lavoro arriva davanti a una persona.
        "awaiting_autopilot_approval" => Destination.new(
          category: :in_progress, execution_phase: "autopilot",
          picker: ->(statuses) { statuses.review_gates.active.ordered.first }
        ),
        # Dopo il sì il lavoro non è più da fare: sta uscendo. È l'ultimo stato di lavoro non di
        # revisione, cioè quello più avanti di tutti fra quelli che l'organizzazione usa per lavorare.
        "closer_staging_queued" => Destination.new(
          category: :in_progress, execution_phase: "closer_staging",
          picker: ->(statuses) { statuses.active.where(review_gate: false).category_in_progress.ordered.last }
        )
      }.freeze

      class << self
        def destination(phase) = DESTINATIONS[phase.to_s]

        # La categoria della FASE, non di una riga di stato. È quello che rende il cancello
        # indipendente dalla configurazione: senza destinazione il cancello continua a chiudere.
        def category(phase) = destination(phase)&.category

        # La domanda la dà il cancello, sulla fase di esecuzione che porta qui: un posto solo. Fase
        # sconosciuta → `mode_for(nil)`, cioè la domanda severa: fail-closed.
        def prerequisites(phase)
          Ticketing::DependencyGuard.mode_for(destination(phase)&.execution_phase)
        end
      end

      # `broadcast: false` quando la mossa la sta già annunciando chi ha deciso: l'approvazione del
      # lavoro annuncia una volta sola e sa se è una di cento, e un secondo annuncio qui rifarebbe per
      # ogni card il giro che l'approvazione di gruppo mette in fondo apposta.
      def initialize(workflow:, actor: nil, broadcast: true)
        @workflow = workflow
        @actor = actor
        @broadcast = broadcast
      end

      # Scrive la parola sul ticket per la fase in cui la lavorazione si trova ADESSO. Chi chiama non
      # nomina nessuno stato: consuma la corrispondenza, non la conosce.
      def call
        destination = self.class.destination(@workflow.phase)
        return Result.ok(@workflow.ticket) if destination.nil?

        status = destination.picker.call(@workflow.organization.ticket_statuses)
        return without_destination if status.nil?

        Ticketing::ChangeStatus.call(organization: @workflow.organization, ticket: @workflow.ticket,
                                     status_id: status.id, channel: :workflow, actor: @actor,
                                     dependency_mode: self.class.prerequisites(@workflow.phase), broadcast: @broadcast)
      end

      private

      def without_destination
        Result.err(AppError.new(I18n.t("member.tickets.errors.no_target_status"), code: "R422-TICKET-008"))
      end
    end
  end
end
