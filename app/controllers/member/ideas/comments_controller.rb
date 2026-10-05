# frozen_string_literal: true

module Member
  module Ideas
    # Discussione su un'idea. Commenta chiunque la vede (visible.ideas → 404, anti-BOLA);
    # il congelamento (converted/archived) è garantito dai service. Eliminare un commento =
    # autore del commento oppure ideas.comment.delete_any.
    class CommentsController < Member::BaseController
      permission_not_required "Commentare un'idea che si vede è baseline: il catalogo dei permessi non ha una " \
                              "chiave per commentare.",
                              only: %i[create]

      include Member::IdeaShowContext

      before_action :set_idea

      def create
        result = ::Ideas::AddComment.call(idea: @idea, author: Current.account, params: comment_params)
        return redirect_to(member_idea_path(@idea), notice: t("member.ideas.comments.created")) if result.ok?

        rerender_with_draft(result)
      end

      def destroy
        comment = @idea.comments.find(params[:id])
        return redirect_to(member_idea_path(@idea), alert: t("member.forbidden")) unless can_delete?(comment)
        return unless confirm_moderation!(comment)

        result = ::Ideas::DeleteComment.call(comment:)
        return redirect_to(member_idea_path(@idea), notice: t("member.ideas.comments.deleted")) if result.ok?

        redirect_to member_idea_path(@idea), alert: result.error.message
      end

      private

      def set_idea
        @idea = visible.ideas.find(params[:idea_id])
      end

      def comment_params
        params.permit(:body)
      end

      # CYRA-728 — moderare è cancellare quello che ha scritto un altro, e passa da una chiave che il
      # catalogo segna pericolosa: qui la conferma serve. Il proprio commento si cancella senza
      # cerimonie — è roba di chi lo cancella, e chiedergli il permesso su sé stesso non protegge
      # nessuno.
      def confirm_moderation!(comment)
        return true if comment.author_id == Current.account.id

        enforce_dangerous_confirmation!("ideas.comment.delete_any", scope: @idea.project)
      end

      def can_delete?(comment)
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        comment.author_id == Current.account.id ||
          can?("ideas.comment.delete_any", scope: @idea.project)
      end

      # Il testo rifiutato torna nel form, ma reso sul posto e non via redirect (CYRA-371): un
      # intervento argomentato non entra nel cookie di sessione — vedi Member::IdeaShowContext.
      def rerender_with_draft(result)
        @comment_draft = comment_params[:body]
        flash.now[:alert] = result.error.message
        load_idea_show_context
        render "member/ideas/show", status: :unprocessable_content
      end
    end
  end
end
