# frozen_string_literal: true

module Member
  # CI health tab of a project (CYRA-1164): one row per CI job with failures, duration, queue wait and
  # flakiness, from the job outcomes GitHub sends. A flaky job opens a ticket with one click (ci.promote);
  # a ticket still open is reused. Flat controller, like ProjectGithubController, so it does not shadow ::Github.
  class ProjectCiHealthController < Member::BaseController
    permission_not_required "The figures of a visible project's CI jobs are read by anyone who sees the project, " \
                            "like errors and usage; opening a ticket from one is gated by ci.promote.",
                            only: :show

    before_action :set_project
    before_action -> { require_permission!("ci.promote", scope: @project) }, only: :promote

    def show
      @repository = @project.github_repository
      @rows = @repository ? ::Github::CiHealth.call(repository: @repository).value : []
      @can_promote = can?("ci.promote", scope: @project)
      @stats = @project.ticket_tally
    end

    def promote
      ci_job = @project.github_repository&.ci_jobs&.find_by(id: params[:id])
      raise ActiveRecord::RecordNotFound if ci_job.nil?

      return redirect_to_ticket(ci_job.open_ticket, "already_promoted") if ci_job.promoted?

      row = ::Github::CiHealth.call(repository: ci_job.repository).value.find { |r| r.ci_job.id == ci_job.id }
      unless row&.flaky?
        return redirect_to(member_project_ci_health_path(@project),
                           alert: t("member.ci_health.not_flaky", days: ::Github::CiHealth::WINDOW.in_days.to_i))
      end

      # The row's job comes from a list; the ticket is built on the record loaded alone.
      result = ::Github::CiHealth::PromoteToTicket.call(row: row.with(ci_job:), reporter: Current.account,
                                                        true_actor: Current.true_account)
      return redirect_to_ticket(result.value, "promoted") if result.ok?

      # A concurrent click won the lock: lead to the ticket it opened.
      return redirect_to_ticket(ci_job.open_ticket, "already_promoted") if ci_job.reload.promoted?

      redirect_to member_project_ci_health_path(@project), alert: t("member.ci_health.promote_failed")
    end

    private

    def redirect_to_ticket(ticket, notice_key)
      redirect_to member_ticket_path(ticket), notice: t("member.ci_health.#{notice_key}")
    end

    # Anti-BOLA: a project you do not see does not exist.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end
  end
end
