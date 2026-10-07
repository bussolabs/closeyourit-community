module Member
  # The owner decides, per kind of action, what their Puck does alone, asks first or never does (CYRA-1017).
  class CoworkerRulesController < BaseController
    before_action :require_prototype
    permission_not_required "Own Puck: the rules only narrow what the owner could already confirm (CYRA-1017)"

    def update
      puck = visible.coworker_puckies.find(params[:coworker_id])
      return head :forbidden unless puck.managed_by?(Current.account)

      action = params[:action_kind].to_s
      raise ActiveRecord::RecordNotFound unless Assistant::Proposal.kinds.key?(action)

      rule = puck.rules.find_or_initialize_by(action: action)
      rule.update!(decision: params.require(:decision))
      redirect_to member_coworker_path(puck, panel: "rules"), status: :see_other
    rescue ActiveRecord::RecordInvalid
      redirect_to member_coworker_path(puck, panel: "rules"), alert: t("member.coworkers.invalid"), status: :see_other
    end

    private

    def require_prototype
      head :not_found unless Coworkers.available_to?(account: Current.account, organization: Current.organization)
    end
  end
end
