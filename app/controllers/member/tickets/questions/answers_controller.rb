# frozen_string_literal: true

module Member
  module Tickets
    module Questions
      # La risposta a UNA domanda (CYRA-782). Il form nomina la domanda: non c'è più niente da
      # indovinare dall'ordine di arrivo.
      class AnswersController < Member::BaseController
        permission_not_required "Rispondere a una domanda è baseline di chi vede il ticket: è una domanda " \
                                "posta a una persona, non una decisione sul lavoro."

        def create
          ticket = visible.tickets.find(params[:ticket_id])
          # CYRA-848 — riservata a chi non la vede = inesistente: lookup ristretto, 404.
          question = ticket.questions.readable_by(Current.account, organization: Current.organization)
                           .find(params[:question_id])

          result = Ticketing::Questions::Reply.call(
            question: question, author: Current.account, body: params[:body], choice: params[:choice]
          )
          redirect_to after_answer_path(ticket),
                      result.ok? ? { notice: t("member.tickets.questions.answered") }
                                 : { alert: result.error.message }
        end

        private

        # CYRA-1288 — answered from an approval card, back to that card: only a card key is a way back.
        APPROVAL_KEY = /\A(review|agent_plan):(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/

        def after_answer_path(ticket)
          if (card = params[:approval].to_s.match(APPROVAL_KEY))
            return member_home_approvals_item_path(kind: card[1], id: card[2])
          end

          member_ticket_path(ticket, tab: params[:return_tab] == "automation" ? "automation" : "questions")
        end
      end
    end
  end
end
