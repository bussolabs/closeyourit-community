# frozen_string_literal: true

module Cli
  module V1
    module Ideas
      # Archiviazione di un'idea come sub-resource SINGLETON: PUT = archivia (open → archived),
      # DELETE = riapri (archived → open). Specchio di Member::IdeasController#archive/#reopen: stesso
      # gate della modifica (autore OPPURE `ideas.edit` sul progetto). Le transizioni e il vincolo
      # "converted è terminale" vivono in Ideas::ChangeStatus (R422-IDEA-002/003). Anti-BOLA: l'idea si
      # risolve dentro @project (già scoped a visible_projects da set_project!) → altra idea/org → R404.
      class ArchivesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_idea
        before_action :require_edit_permission

        def update
          respond(::Ideas::ChangeStatus.call(idea: @idea, to: :archived))
        end

        def destroy
          respond(::Ideas::ChangeStatus.call(idea: @idea, to: :open))
        end

        private

        def respond(result)
          if result.ok?
            render_ok(IdeaSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def set_idea
          @idea = @project.ideas.find(params[:idea_id])
        end

        # L'autore archivia/riapre sempre la propria idea; su quelle altrui serve ideas.edit sul progetto.
        def require_edit_permission
          return if @idea.authored_by?(Current.account)

          require_permission!("ideas.edit", scope: @project)
        end
      end
    end
  end
end
