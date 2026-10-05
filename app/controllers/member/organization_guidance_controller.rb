# frozen_string_literal: true

module Member
  # Hub Guidance dell'organizzazione (CYRA-75): references + procedures LOCALI del livello org — la base
  # della catena che org → gruppo → progetto ereditano. Niente preview (si risolve su un progetto).
  # Gate organization.manage. Owner = Current.organization (nessun id nel path).
  class OrganizationGuidanceController < Member::BaseController
    before_action :require_manage

    def show
      @references = Current.organization.guidance_references.ordered
      @procedures = Current.organization.guidance_procedures.ordered
    end

    private

    def require_manage
      require_permission!("organization.manage")
    end
  end
end
