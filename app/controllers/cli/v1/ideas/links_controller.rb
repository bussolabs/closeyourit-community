# frozen_string_literal: true

module Cli
  module V1
    module Ideas
      # Collegamenti fra idee via CLI (CYRA-845): POST collega (`target_id` + `kind` related|evolution),
      # DELETE scollega (:id = l'altra idea, in qualunque verso). Stesso gate della modifica idea
      # (autore OPPURE ideas.edit), specchio di Member::Ideas::LinksController. Anti-BOLA: l'idea
      # si risolve dentro @project (visible_projects) → R404; l'altra idea nel suo progetto (service).
      class LinksController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_idea
        before_action :require_edit_permission

        def create
          result = ::Ideas::LinkIdeas.call(idea: @idea, target_id: params[:target_id],
                                           kind: params.fetch(:kind, "related"))
          if result.ok?
            render_created(IdeaSerializer.new(@idea.reload))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          result = ::Ideas::UnlinkIdeas.call(idea: @idea, other_id: params[:id])
          if result.ok?
            render_no_content
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        def set_idea
          @idea = @project.ideas.find(params[:idea_id])
        end

        def require_edit_permission
          return if @idea.authored_by?(Current.account)

          require_permission!("ideas.edit", scope: @project)
        end
      end
    end
  end
end
