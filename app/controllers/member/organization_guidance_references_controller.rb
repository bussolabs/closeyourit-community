# frozen_string_literal: true

module Member
  # CRUD delle references di guidance LOCALI dell'organizzazione (CYRA-75). Gate organization.manage.
  class OrganizationGuidanceReferencesController < Member::BaseController
    include Member::GuidanceReferenceActions

    before_action :require_manage
    before_action :set_guidance_reference, only: %i[edit update destroy]

    private

    def require_manage
      require_permission!("organization.manage")
    end

    def guidance_owner = Current.organization
    def guidance_home_path = member_organization_guidance_path
    def guidance_collection_url = member_organization_guidance_references_path
    def guidance_member_url(reference) = member_organization_guidance_reference_path(reference)
    # Livello e nome dichiarati dal form condiviso ai tre livelli (CYRA-576).
    def guidance_level = :organization
    def guidance_scope_name = Current.organization.name
  end
end
