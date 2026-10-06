# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      module Questions
        # La risposta a UNA domanda via CLI (CYRA-783).
        class AnswersController < Cli::V1::BaseController
          before_action :set_project!

          def create
            ticket = find_ticket!(@project, params[:ticket_id])
            # CYRA-848 — riservata a chi non la vede = inesistente: lookup ristretto, 404.
            question = ticket.questions.readable_by(Current.account, organization: Current.organization)
                             .find(params[:question_id])

            result = ::Ticketing::Questions::Reply.call(
              question: question, author: Current.account, body: params[:body]
            )
            if result.ok?
              render_created(QuestionSerializer.new(question.reload))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end
        end
      end
    end
  end
end
