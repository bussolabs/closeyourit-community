module Member
  # The monthly token ceiling of the organization's Puckies; only who manages the organization sets it (CYRA-1027).
  class CoworkerBudgetsController < BaseController
    include CoworkerScoped
    permission_not_required "Checked inline: organization.manage, because the budget belongs to the organization (CYRA-1027)"

    def update
      return head :forbidden unless Authorization::Resolver.new(account: Current.account, organization: Current.organization).can?("organization.manage")

      budget = Coworkers::Budget.find_or_initialize_by(organization: Current.organization)
      budget.update!(monthly_token_cap: params[:monthly_token_cap].presence)
      back_to_panel("rules")
    rescue ActiveRecord::RecordInvalid
      back_to_panel("rules", alert: t("member.coworkers.invalid"))
    end
  end
end
