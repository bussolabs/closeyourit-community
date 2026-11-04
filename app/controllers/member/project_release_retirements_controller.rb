# frozen_string_literal: true

module Member
  # Retire a release with a message for its users, or restore it (CYRA-1161). Gate projects.edit;
  # the retire also wants the confirm its dialog sends. Flat controller, like the project tokens.
  class ProjectReleaseRetirementsController < Member::BaseController
    before_action :set_release
    before_action -> { require_permission!("projects.edit", scope: @project) }

    def create
      unless Authorization::DangerousAction.confirmed?(params[:confirm])
        return back_to_project(alert: t("member.projects.release_retirement.confirmation_required"))
      end

      result = ::Projects::Releases::Retire.call(release: @release, message: params[:message], actor: Current.account,
                                                 true_actor: Current.true_account)
      return back_to_project(alert: result.error.message) unless result.ok?

      back_to_project(notice: t("member.projects.release_retirement.retired_notice", version: @release.display_version))
    end

    def destroy
      ::Projects::Releases::Restore.call(release: @release, actor: Current.account, true_actor: Current.true_account)
      back_to_project(notice: t("member.projects.release_retirement.restored_notice", version: @release.display_version))
    end

    private

    # Anti-BOLA: a project out of sight, or a release of another project, is a 404.
    def set_release
      @project = visible.projects.find(params[:project_id])
      @release = @project.releases.find(params[:release_id])
    end

    def back_to_project(**flash)
      redirect_to member_project_path(@project), **flash
    end
  end
end
