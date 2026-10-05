# frozen_string_literal: true

module Member
  module Tickets
    # Domande di primo livello su un ticket (CYRA-782).
    class QuestionsController < Member::BaseController
      permission_not_required "Fare una domanda è baseline di chi vede il ticket: è una conversazione, " \
                              "non una decisione sul lavoro.", only: :create

      before_action :set_ticket

      def create
        # Marcare una domanda BLOCCANTE ferma la coda degli agenti su questo ticket: è una leva sul
        # lavoro, non una conversazione, e chi non può modificare il ticket non può tirarla. La domanda
        # si pone lo stesso — semplicemente non blocca.
        blocking = params[:blocking].present? && can?("tickets.edit", scope: @ticket.project)
        result = Ticketing::Questions::Ask.call(
          ticket: @ticket, author: Current.account, body: params[:body],
          blocking: blocking, audience: audience
        )
        redirect_to_tab(result.ok? ? { notice: t("member.tickets.questions.asked") }
                                   : { alert: result.error.message })
      end

      def destroy
        # CYRA-848 — riservata a chi non la vede = inesistente: lookup ristretto, 404.
        question = @ticket.questions.readable_by(Current.account, organization: Current.organization)
                          .find(params[:id])
        # Cancellare la parola di un altro è lo stesso gesto che sui commenti, e passa dalla stessa
        # chiave: una in più sarebbe una riga in più nel catalogo, negli spec dei metadati e in ogni
        # matrice di ruolo, per la stessa semantica.
        unless question.author_id == Current.account.id
          require_permission!("tickets.comment.delete_any", scope: @ticket.project)
          # `require_permission!` in area member RENDE (redirect con avviso) e ritorna il redirect,
          # che è truthy: `or return` non scatterebbe mai e l'azione proseguirebbe fino a un secondo
          # redirect. Si guarda `performed?`, come fanno gli altri controller di questo namespace.
          return if performed?
        end
        note_permission_check!

        question.destroy
        redirect_to_tab(notice: t("member.tickets.questions.deleted"))
      end

      private

      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end

      # Il riservato è il default: una domanda che sfugge al cliente per svista è un danno, una
      # domanda interna che andava condivisa è un click.
      def audience
        params[:audience].to_s == "shared" ? :shared : :internal
      end

      def redirect_to_tab(flash_options)
        redirect_to member_ticket_path(@ticket, tab: "questions"), flash_options
      end
    end
  end
end
