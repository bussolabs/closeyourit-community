# frozen_string_literal: true

module Member
  module Tickets
    module Questions
      # Il ritiro di una domanda senza risposta (CYRA-782).
      #
      # Esiste perché una domanda bloccante trattiene il ticket: senza una strada per ritirarla, una
      # domanda posta per sbaglio fermerebbe il lavoro finché qualcuno non inventa una risposta pur di
      # sbloccarlo. Passa da `tickets.edit` come il marcarla bloccante: è la stessa leva, al contrario.
      class ClosuresController < Member::BaseController
        def update
          ticket = visible.tickets.find(params[:ticket_id])
          require_permission!("tickets.edit", scope: ticket.project)
          return if performed?

          # CYRA-848 — riservata a chi non la vede = inesistente: lookup ristretto, 404.
          question = ticket.questions.readable_by(Current.account, organization: Current.organization)
                           .find(params[:question_id])
          result = ::Ticketing::Questions::Close.call(question: question, actor: Current.account)
          redirect_to member_ticket_path(ticket, tab: "questions"),
                      result.ok? ? { notice: t("member.tickets.questions.closed") }
                                 : { alert: result.error.message }
        end
      end
    end
  end
end
