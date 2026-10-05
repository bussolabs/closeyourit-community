# frozen_string_literal: true

module Member
  module Ideas
    # Sintesi AI di un'idea (idea + commenti → bozza ticket). Accoda una Ai::Request e risponde
    # 202: la pagina di conversione polla /member/ai/requests/:id e prefila i campi. Stesso gate
    # della conversione (autore o ideas.convert), solo su idee aperte. Endpoint JSON (Stimulus).
    class SynthesesController < Member::BaseController
      before_action :set_idea

      def create
        unless convertible_by_current_account?
          return render json: { error: { code: "R403-IDEA-001", message: t("member.forbidden") } },
                        status: :forbidden
        end
        if @idea.status_converted?
          return render json: { error: { code: "R422-IDEA-003", message: t("ideas.errors.already_converted") } },
                        status: :unprocessable_content
        end
        if @idea.locked?
          return render json: { error: { code: "R422-IDEA-002", message: t("ideas.errors.locked") } },
                        status: :unprocessable_content
        end

        enqueue_ai_request!(kind: "idea_synthesize", args: { idea_id: @idea.id })
      end

      private

      def set_idea
        @idea = visible.ideas.find(params[:idea_id])
      end

      def convertible_by_current_account?
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        @idea.authored_by?(Current.account) || can?("ideas.convert", scope: @idea.project)
      end
    end
  end
end
