# frozen_string_literal: true

module Member
  # CRUD delle procedures di guidance LOCALI del gruppo (CYRA-75). Gate project_groups.manage.
  class GroupGuidanceProceduresController < Member::BaseController
    include Member::GuidanceProcedureActions

    before_action :set_group
    before_action :require_manage
    before_action :set_guidance_procedure, only: %i[edit update destroy]

    private

    def set_group
      @group = Current.organization.groups.find(params[:group_id])
    end

    def require_manage
      require_permission!("project_groups.manage")
    end

    def guidance_owner = @group
    def guidance_home_path = member_group_guidance_path(@group)
    def guidance_collection_url = member_group_guidance_procedures_path(@group)
    def guidance_member_url(procedure) = member_group_guidance_procedure_path(@group, procedure)
    # Livello e nome dichiarati dal form condiviso ai tre livelli (CYRA-576).
    def guidance_level = :group
    def guidance_scope_name = @group.name
  end
end
