# frozen_string_literal: true

module Member
  module Ideas
    # Collegamenti fra idee dalla pagina idea (CYRA-845): «Collega un'idea» (parenti alla pari) e
    # «Scollega». Le evoluzioni nascono dal form di proposta (evolves_id), non da qui; scollegarle
    # sì. Stesso gate della modifica idea (autore o ideas.edit): sono contenuto, non discussione.
    # Anti-BOLA via visible.ideas → 404; l'altra idea si risolve nel progetto (service).
    class LinksController < Member::BaseController
      before_action :set_idea
      before_action :require_manage!

      def create
        result = ::Ideas::LinkIdeas.call(idea: @idea, target_id: params[:target_id], kind: :related)
        notice_or_alert(result, t("member.ideas.links.created"))
      end

      def destroy
        result = ::Ideas::UnlinkIdeas.call(idea: @idea, other_id: params[:id])
        notice_or_alert(result, t("member.ideas.links.deleted"))
      end

      private

      def set_idea
        @idea = visible.ideas.find(params[:idea_id])
      end

      def require_manage!
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        return if @idea.authored_by?(Current.account)

        require_permission!("ideas.edit", scope: @idea.project)
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
