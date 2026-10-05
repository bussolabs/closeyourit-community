# frozen_string_literal: true

module Cli
  module V1
    module Ideas
      # Case di un'idea via CLI (esempi/scenari concreti). I case sono contenuto dell'idea, non
      # discussione: stesso gate della modifica idea (autore OPPURE `ideas.edit`), specchio di
      # Member::Ideas::CasesController. Il congelamento (converted/archived) è garantito da
      # Ideas::AddCase (R422-IDEA-002). Anti-BOLA: l'idea si risolve dentro @project (già scoped
      # da set_project! a visible_projects) → idea di un altro progetto/org → R404.
      class CasesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_idea
        before_action :require_edit_permission
        before_action :set_case, only: %i[update destroy]

        def create
          result = ::Ideas::AddCase.call(idea: @idea, params: case_params)
          if result.ok?
            render_created(IdeaCaseSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def update
          result = ::Ideas::UpdateCase.call(case_record: @case, params: case_params)
          if result.ok?
            render_ok(IdeaCaseSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          result = ::Ideas::DeleteCase.call(case_record: @case)
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

        # Anti-BOLA: il case si risolve DENTRO @idea (già scoped a @project visibile) → un case di
        # un'altra idea/progetto/org → RecordNotFound → R404.
        def set_case
          @case = @idea.cases.find(params[:id])
        end

        # Contenuto dell'idea → stesso permesso della modifica idea (autore o ideas.edit).
        def require_edit_permission
          return if @idea.authored_by?(Current.account)

          require_permission!("ideas.edit", scope: @project)
        end

        def case_params
          params.permit(:title, :description)
        end
      end
    end
  end
end
