# frozen_string_literal: true

module Member
  # CRUD delle procedures di guidance LOCALI dell'organizzazione (CYRA-75). Gate organization.manage.
  class OrganizationGuidanceProceduresController < Member::BaseController
    include Member::GuidanceProcedureActions

    before_action :require_manage
    before_action :set_guidance_procedure, only: %i[edit update destroy]

    private

    def require_manage
      require_permission!("organization.manage")
    end

    def guidance_owner = Current.organization
    def guidance_home_path = member_organization_guidance_path
    def guidance_collection_url = member_organization_guidance_procedures_path
    def guidance_member_url(procedure) = member_organization_guidance_procedure_path(procedure)
    # Livello e nome dichiarati dal form condiviso ai tre livelli (CYRA-576).
    def guidance_level = :organization
    def guidance_scope_name = Current.organization.name
  end
end
