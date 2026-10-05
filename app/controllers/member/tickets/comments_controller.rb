# frozen_string_literal: true

module Member
  module Tickets
    # Discussione su un ticket. Il ticket è risolto con lo scoping di visibilità Fase E
    # (visible.tickets) → 404 se l'utente non lo vede. Tutti i ruoli che vedono il
    # ticket possono commentare; eliminare un commento = autore oppure admin/owner.
    #
    # Ogni ritorno punta alla scheda Discussione (CYRA-219): commentare da lì e ritrovarsi sul
    # Dettaglio, senza il proprio commento davanti, sembra che il commento non sia stato salvato.
    class CommentsController < Member::BaseController
      permission_not_required "Commentare un ticket che si vede è baseline: il catalogo dei permessi non ha una " \
                              "chiave per commentare.",
                              only: %i[create]

      before_action :set_ticket

      def create
        result = Ticketing::AddComment.call(
          ticket: @ticket, author: Current.account, params: comment_params
        )
        notice_or_alert(result, t("member.tickets.comments.created"))
      end

      def destroy
        comment = @ticket.comments.find(params[:id])
        return redirect_to(discussion_path, alert: t("member.forbidden")) unless can_delete?(comment)
        return unless confirm_moderation!(comment)

        result = Ticketing::DeleteComment.call(
          comment: comment, actor: Current.account, true_actor: Current.true_account
        )
        if result.ok?
          redirect_to discussion_path, notice: t("member.tickets.comments.deleted")
        else
          redirect_to discussion_path, alert: result.error.message
        end
      end

      private

      def discussion_path = member_ticket_path(@ticket, tab: "discussion")

      # Anti-BOLA + scoping: ticket non visibile (o di altra org) → RecordNotFound (404).
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end

      def comment_params
        params.permit(:body, files: [])
      end

      # CYRA-728 — moderare è cancellare quello che ha scritto un altro, e passa da una chiave che il
      # catalogo segna pericolosa: qui la conferma serve. Il proprio commento si cancella senza
      # cerimonie — è roba di chi lo cancella, e chiedergli il permesso su sé stesso non protegge
      # nessuno.
      def confirm_moderation!(comment)
        return true if comment.author_id == Current.account.id

        enforce_dangerous_confirmation!("tickets.comment.delete_any", scope: @ticket.project)
      end

      def can_delete?(comment)
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        !comment.automation_generated? && (comment.author_id == Current.account.id ||
          can?("tickets.comment.delete_any", scope: @ticket.project)
        )
      end

      def notice_or_alert(result, notice)
        return redirect_to(discussion_path, notice: notice) if result.ok?

        # Il testo scritto NON si butta. Col tetto a 240 caratteri il rifiuto diventa un evento
        # ordinario, e un redirect che svuota la textarea farebbe perdere un commento appena scritto:
        # succede una volta sola, poi la gente smette di usare la discussione. Il form lo ripesca da
        # flash[:comment_draft].
        flash[:comment_draft] = comment_params[:body]
        redirect_to discussion_path, alert: result.error.message
      end
    end
  end
end
