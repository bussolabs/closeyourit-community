# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Override umano del gate di eleggibilità agenti (CYRA-184) dal canale CLI: parità con
      # Member::Tickets::EligibilitiesController, stesso service e stesso gate `tickets.edit`.
      # Singleton come status/reviewer — e come lì, il campo NON è in ticket_params: si cambia solo
      # da qui. Anti-BOLA: ticket dentro @project (visible_projects) → fuori scope = R404.
      class EligibilitiesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        DECISIONS = { "allowed" => :human, "blocked" => :human, "auto" => :reset }.freeze

        def update
          return unless require_permission!("tickets.edit", scope: @project)

          decision = params[:eligibility].to_s
          source = DECISIONS[decision]
          return invalid_decision if source.nil?

          result = Ticketing::SetAgentEligibility.call(
            ticket: @ticket, source: source,
            eligibility: (decision unless source == :reset),
            reason: params[:reason].presence,
            actor: Current.account, true_actor: Current.account
          )
          if result.err?
            return render_error(result.error.code, result.error.message,
                                status: result.error.status, details: result.error.details)
          end

          # Il reset non è una decisione ma una richiesta di riesame: va accodata subito. Senza il
          # servizio collegato non si accoda niente e il ticket resta pending (CYRA-548).
          Ticketing::AgentEligibilityQueue.enqueue(ticket: @ticket, wait: nil) if source == :reset
          render_ok(TicketSerializer.new(@ticket.reload))
        end

        private

        def invalid_decision
          render_error("R422-TICKET-014", "eligibility deve essere allowed, blocked o auto",
                       status: :unprocessable_content)
        end

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
