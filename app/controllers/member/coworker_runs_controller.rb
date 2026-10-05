module Member
  class CoworkerRunsController < BaseController
    before_action :require_prototype
    permission_not_required "Local prototype: runs are scoped through the account-owned Puck in the current organization"

    def create
      puck = visible.coworker_puckies.find(params[:coworker_id])
      run = Coworkers::Start.call(puck: puck, kind: params[:kind], input: params[:input])
      redirect_to member_coworker_path(puck, panel: params[:kind] == "task" ? "tasks" : nil, anchor: "coworker_run_#{run.id}"), status: :see_other
    rescue Coworkers::Start::Busy
      redirect_to member_coworker_path(puck), alert: t("member.coworkers.busy")
    rescue ActiveRecord::RecordInvalid
      redirect_to member_coworker_path(puck), alert: t("member.coworkers.invalid")
    end

    def approve
      puck = visible.coworker_puckies.find(params[:coworker_id])
      proposal = puck.runs.find(params[:id])
      task = Coworkers::Start.call(puck: puck, kind: "task", proposal_run: proposal)
      redirect_to member_coworker_path(puck, anchor: "coworker_task_progress_#{task.id}"), status: :see_other
    rescue Coworkers::Start::InvalidProposal
      redirect_to member_coworker_path(puck), alert: t("member.coworkers.proposal_expired")
    rescue Coworkers::Start::Busy
      redirect_to member_coworker_path(puck), alert: t("member.coworkers.busy")
    end

    def repeat
      puck = visible.coworker_puckies.find(params[:coworker_id])
      failed = puck.runs.find(params[:id])
      raise ActiveRecord::RecordNotFound unless failed.retryable?

      run = Coworkers::Start.call(puck: puck, kind: failed.kind, input: failed.input)
      redirect_to member_coworker_path(puck, anchor: "coworker_run_#{run.id}"), status: :see_other
    rescue Coworkers::Start::Busy
      redirect_to member_coworker_path(puck), alert: t("member.coworkers.busy")
    end

    def update
      puck = visible.coworker_puckies.find(params[:coworker_id])
      run = puck.runs.find(params[:id])
      run.update!(stop_requested: true) if run.active?
      redirect_to member_coworker_path(puck), status: :see_other
    end

    private

    def require_prototype
      head :not_found unless Coworkers.available_to?(account: Current.account, organization: Current.organization)
    end
  end
end
