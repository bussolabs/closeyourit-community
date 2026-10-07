module Member
  # Puck pages exist only where Coworkers is available, and only for the owner's own Puckies.
  module CoworkerScoped
    extend ActiveSupport::Concern

    included do
      before_action :require_coworkers
    end

    private

    def require_coworkers
      head :not_found unless Coworkers.available_to?(account: Current.account, organization: Current.organization)
    end

    def coworker_puck = @coworker_puck ||= visible.coworker_puckies.find(params[:coworker_id])

    # Rules, memory, schedules and watch of a team Puck belong to who manages the organization (CYRA-1023).
    def require_coworker_manager
      head :forbidden unless coworker_puck.managed_by?(Current.account)
    end

    def back_to_panel(panel, **options)
      redirect_to member_coworker_path(coworker_puck, panel: panel), status: :see_other, **options
    end
  end
end
