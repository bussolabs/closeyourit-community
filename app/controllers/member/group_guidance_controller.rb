# frozen_string_literal: true

module Member
  # Hub Guidance del gruppo (macro-progetto, CYRA-75): references + procedures LOCALI del livello gruppo.
  # Niente preview: il contesto effettivo si risolve su un PROGETTO (Guidance::Resolve richiede un
  # progetto). Gate project_groups.manage. Controller flat, scoping anti-BOLA all'org corrente.
  class GroupGuidanceController < Member::BaseController
    before_action :set_group
    before_action :require_manage

    def show
      @references = @group.guidance_references.ordered
      @procedures = @group.guidance_procedures.ordered
    end

    private

    # Anti-BOLA: un gruppo di un'altra org → RecordNotFound (come Member::GroupsController#set_group).
    def set_group
      @group = Current.organization.groups.find(params[:group_id])
    end

    def require_manage
      require_permission!("project_groups.manage")
    end
  end
end
