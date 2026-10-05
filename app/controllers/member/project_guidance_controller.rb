# frozen_string_literal: true

module Member
  # Hub Guidance del progetto (tab Guidance, CYRA-75): references + procedures LOCALI + PREVIEW del
  # contesto effettivo (Guidance::Preview, che affianca Guidance::Resolve annotando origine e override).
  # Gate projects.edit come la tab Settings. Controller flat per non ombreggiare ::Projects/::Guidance.
  class ProjectGuidanceController < Member::BaseController
    before_action :set_project
    before_action :require_edit

    def show
      @references = @project.guidance_references.ordered
      @procedures = @project.guidance_procedures.ordered
      @preview = Guidance::Preview.call(project: @project)
      @stats = @project.ticket_tally
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_edit
      require_permission!("projects.edit", scope: @project)
    end
  end
end
