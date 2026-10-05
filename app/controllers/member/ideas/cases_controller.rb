# frozen_string_literal: true

module Member
  module Ideas
    # Case di un'idea (esempi/scenari concreti). Aggiunge/modifica/elimina chi possiede l'idea
    # oppure ha ideas.edit sul progetto: i case sono contenuto dell'idea, non discussione, quindi
    # stesso gate della modifica idea (non comment.delete_any). Il congelamento (converted/archived)
    # è garantito dai service. Anti-BOLA via visible.ideas → 404.
    class CasesController < Member::BaseController
      before_action :set_idea
      before_action :require_manage!

      def create
        result = ::Ideas::AddCase.call(idea: @idea, params: case_params)
        notice_or_alert(result, t("member.ideas.cases.created"))
      end

      def update
        case_record = @idea.cases.find(params[:id])
        result = ::Ideas::UpdateCase.call(case_record:, params: case_params)
        notice_or_alert(result, t("member.ideas.cases.updated"))
      end

      def destroy
        case_record = @idea.cases.find(params[:id])
        result = ::Ideas::DeleteCase.call(case_record:)
        notice_or_alert(result, t("member.ideas.cases.deleted"))
      end

      private

      def set_idea
        @idea = visible.ideas.find(params[:idea_id])
      end

      # Contenuto dell'idea → stesso permesso della modifica idea (autore o ideas.edit).
      def require_manage!
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        return if @idea.authored_by?(Current.account)

        require_permission!("ideas.edit", scope: @idea.project)
      end

      def case_params
        params.permit(:title, :description)
      end

      def notice_or_alert(result, notice)
        if result.ok?
          redirect_to member_idea_path(@idea), notice: notice
        else
          redirect_to member_idea_path(@idea), alert: result.error.message
        end
      end
    end
  end
end
