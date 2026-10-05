# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      module Questions
        # Il ritiro di una domanda senza risposta via CLI (CYRA-783). Stessa leva del marcarla
        # bloccante, al contrario: passa da `tickets.edit`.
        class ClosuresController < Cli::V1::BaseController
          before_action :set_project!

          def update
            ticket = find_ticket!(@project, params[:ticket_id])
            require_permission!("tickets.edit", scope: @project) or return

            # CYRA-848 — riservata a chi non la vede = inesistente: lookup ristretto, 404.
            question = ticket.questions.readable_by(Current.account, organization: Current.organization)
                             .find(params[:question_id])
            result = ::Ticketing::Questions::Close.call(question: question, actor: Current.account)
            if result.ok?
              render_ok(QuestionSerializer.new(question.reload))
            else
              render_error(result.error.code, result.error.message, status: result.error.status)
            end
          end
        end
      end
    end
  end
end
