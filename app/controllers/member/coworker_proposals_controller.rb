module Member
  # The owner confirms or discards an action their Puck proposed; Confirm re-checks permission and
  # the run's frozen scope (CYRA-1010).
  class CoworkerProposalsController < BaseController
    before_action :require_prototype
    before_action :load_proposal
    permission_not_required "Own Puck; each action re-checks its own permission at confirm time (CYRA-1010)"

    def confirm
      outcome = Assistant::Proposals::Confirm.call(proposal: @proposal, account: Current.account, organization: Current.organization,
                                                   true_actor: Current.true_account,
                                                   allowed_project_ids: Coworkers::Scope.snapshot(@proposal.coworkers_run).project_ids)
      flash[:alert] = outcome.error.message if outcome.err?
      back
    end

    def discard
      @proposal.update!(status: :discarded) if @proposal.confirmable?
      back
    end

    private

    def require_prototype
      head :not_found unless Coworkers.available_to?(account: Current.account, organization: Current.organization)
    end

    def load_proposal
      @puck = visible.coworker_puckies.find(params[:coworker_id])
      @proposal = Assistant::Proposal.where(coworkers_run_id: @puck.runs.select(:id), account_id: Current.account.id).find(params[:id])
    end

    def back
      @proposal.coworkers_run.publish
      redirect_to member_coworker_path(@puck, anchor: "coworker_run_#{@proposal.coworkers_run_id}"), status: :see_other
    end
  end
end
