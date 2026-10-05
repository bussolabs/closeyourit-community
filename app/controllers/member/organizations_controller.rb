# frozen_string_literal: true

module Member
  # Impostazioni dell'organizzazione corrente (rinomina). Solo owner.
  class OrganizationsController < Member::BaseController
    before_action :require_owner

    def edit
      @organization = Current.organization
      @accounts = member_accounts
    end

    def update
      @organization = Current.organization
      if @organization.update(organization_params)
        redirect_to edit_member_organization_path, notice: t("member.organization.updated")
      else
        @errors = @organization.errors.to_hash
        @accounts = member_accounts
        render :edit, status: :unprocessable_content
      end
    end

    private

    def organization_params
      params.permit(:name, :slug, :default_projects_view, :logs_retention_days, :analytics_retention_days,
                    :errors_retention_days, :performance_retention_days, :servers_retention_days,
                    :uptime_retention_days, :traces_retention_days, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days, :default_assignee_id, :cto_id)
    end

    # Membri dell'org candidabili come assegnatario di default (l'assignee dev'essere membro dell'org).
    def member_accounts
      Current.organization.accounts.order(:name)
    end

    def require_owner
      require_permission!("organization.manage")
    end
  end
end
