# frozen_string_literal: true

module Member
  # CRUD delle references di guidance LOCALI del progetto (CYRA-75). Logica in
  # Member::GuidanceReferenceActions; qui owner, gate (projects.edit) e path. Controller flat.
  class ProjectGuidanceReferencesController < Member::BaseController
    include Member::GuidanceReferenceActions

    before_action :set_project
    before_action :require_edit
    before_action :set_guidance_reference, only: %i[edit update destroy]

    private

    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_edit
      require_permission!("projects.edit", scope: @project)
    end

    def guidance_owner = @project
    def guidance_home_path = member_project_guidance_path(@project)
    def guidance_collection_url = member_project_guidance_references_path(@project)
    def guidance_member_url(reference) = member_project_guidance_reference_path(@project, reference)
    # Livello e nome dichiarati dal form condiviso ai tre livelli (CYRA-576).
    def guidance_level = :project
    def guidance_scope_name = @project.name
  end
end
