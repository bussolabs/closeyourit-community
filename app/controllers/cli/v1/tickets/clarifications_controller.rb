# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Stato del ciclo di chiarimenti di un ticket (CYRA-221). Sola lettura: le domande le scrive il
      # server quando il triage le consegna (Agents::Attempts::Deliver → Agents::Clarifications::Ask),
      # non un chiamante esterno.
      #
      # È il canale che sostituisce il ri-parsing dei commenti: skill di triage e automator leggono lo
      # stato da qui invece di cercare un marker HTML nel testo della discussione. Baseline come i
      # commenti — chi vede il progetto (set_project! → visibilità Fase E) vede lo stato del suo ticket.
      class ClarificationsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def index
          # `::Agents`, non `Agents`: dentro Cli::V1 il lookup relativo cerca prima Cli::V1::Agents e
          # muore con un NameError che parla di una costante che non esiste da nessuna parte.
          snapshot = ::Agents::Clarifications::State.call(workflow: @ticket.agent_workflow)
          render_ok(ClarificationStateSerializer.new(snapshot))
        end

        private

        # Ticket dentro il progetto già scoped a visible_projects (set_project!): anti-BOLA, un ticket
        # fuori dalla visibilità → RecordNotFound → R404, mai 403. UUID o code umano.
        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
