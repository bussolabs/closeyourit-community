# frozen_string_literal: true

module Member
  # CRUD delle procedures di guidance LOCALI del progetto (CYRA-75). Gate projects.edit. Controller flat.
  class ProjectGuidanceProceduresController < Member::BaseController
    include Member::GuidanceProcedureActions

    before_action :set_project
    before_action :require_edit
    before_action :set_guidance_procedure, only: %i[edit update destroy]

    private

    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_edit
      require_permission!("projects.edit", scope: @project)
    end

    def guidance_owner = @project
    def guidance_home_path = member_project_guidance_path(@project)
    def guidance_collection_url = member_project_guidance_procedures_path(@project)
    def guidance_member_url(procedure) = member_project_guidance_procedure_path(@project, procedure)
    # Livello e nome dichiarati dal form condiviso ai tre livelli (CYRA-576).
    def guidance_level = :project
    def guidance_scope_name = @project.name
  end
end
