# frozen_string_literal: true

module Member
  module Tickets
    # Override umano dell'eleggibilità agenti (CYRA-184): consentire o bloccare un ticket a mano, o
    # riportarlo alla valutazione automatica. Singleton come il voto e il watch — l'identità è il
    # ticket parent — e deliberatamente FUORI da ticket_params: decidere se un agente autonomo può
    # lavorare un ticket è una scelta di sicurezza, non un campo del form di modifica.
    #
    # Gate v1 = tickets.edit: nessuna chiave RBAC nuova, così nessuna organizzazione rischia di
    # ritrovarsi senza nessuno in grado di sbloccare un ticket dopo il rilascio.
    class EligibilitiesController < Member::BaseController
      before_action :set_ticket
      before_action -> { require_permission!("tickets.edit", scope: @ticket.project) }

      DECISIONS = { "allowed" => :human, "blocked" => :human, "auto" => :reset }.freeze

      def update
        decision = params[:eligibility].to_s
        source = DECISIONS[decision]
        return redirect_back_with_alert(t("member.tickets.agent_eligibility.errors.invalid")) if source.nil?

        result = Ticketing::SetAgentEligibility.call(
          ticket: @ticket, source: source,
          eligibility: (decision unless source == :reset),
          reason: reason_for(decision),
          actor: Current.account, true_actor: Current.true_account
        )
        return redirect_back_with_alert(result.error.message) if result.err?

        # Il reset non è una decisione, è una richiesta di valutazione: va ri-accodata subito, senza
        # debounce (l'utente ha appena premuto il pulsante e sta aspettando un esito). Senza il
        # servizio collegato non si accoda: il ticket resta pending e la sua pagina dice perché.
        Ticketing::AgentEligibilityQueue.enqueue(ticket: @ticket, wait: nil) if source == :reset

        redirect_back fallback_location: member_ticket_path(@ticket),
                      notice: t("member.tickets.agent_eligibility.updated.#{decision}")
      end

      private

      # La motivazione umana è opzionale: se non la scrive, ne mettiamo una che dica almeno CHI ha
      # deciso, così la pagina non resta con la motivazione del modello sotto un verdetto opposto.
      def reason_for(decision)
        return if decision == "auto"

        params[:reason].presence || t("member.tickets.agent_eligibility.manual_reason",
                                      name: Current.account.name)
      end

      def redirect_back_with_alert(message)
        redirect_back fallback_location: member_ticket_path(@ticket), alert: message
      end

      # Anti-BOLA + scoping: ticket non visibile (o di altra org) → RecordNotFound (404).
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end
    end
  end
end
