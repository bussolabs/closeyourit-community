# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Domande di un ticket via CLI (CYRA-783). Thin adapter sui service condivisi, come i commenti.
      class QuestionsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        # Lettura = baseline (chi vede il ticket), MENO le domande riservate al gruppo di lavoro se
        # chi legge è un cliente (CYRA-848, regola in Ticketing::Question.readable_by). `includes`
        # speculare al serializer: senza, una query per domanda e una per risposta.
        def index
          questions, meta = paginate(readable_questions.chronological
                                            .includes(:author, :closed_by, answers: :author))
          render_ok(QuestionSerializer.new(questions), meta: meta)
        end

        def create
          # Marcare una domanda BLOCCANTE ferma la coda degli agenti: è una leva sul lavoro, non una
          # conversazione. Senza il permesso la domanda si pone lo stesso, semplicemente non blocca —
          # rifiutarla per intero punirebbe chi voleva solo chiedere.
          # `authorization.can?` e non `require_permission!`: qui non si nega la richiesta, si decide
          # se una spunta vale. `can?` è helper delle viste e lato CLI non esiste.
          blocking = ActiveModel::Type::Boolean.new.cast(params[:blocking]).present? &&
                     authorization.can?("tickets.edit", scope: @project)
          result = ::Ticketing::Questions::Ask.call(
            ticket: @ticket, author: Current.account, body: params[:body],
            blocking: blocking, audience: params[:audience].to_s == "shared" ? :shared : :internal
          )
          render_service(result) { |question| render_created(QuestionSerializer.new(question)) }
        end

        def destroy
          question = readable_questions.find(params[:id])
          unless question.author_id == Current.account.id
            require_permission!("tickets.comment.delete_any", scope: @project) or return
          end

          question.destroy
          render_no_content
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # CYRA-848 — una domanda che non si può leggere non si può nemmeno eliminare: il lookup
        # ristretto la fa sparire (404) invece di confermarne l'esistenza con un permesso negato.
        def readable_questions
          @ticket.questions.readable_by(Current.account, organization: Current.organization)
        end

        def render_service(result)
          return yield(result.value) if result.ok?

          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
