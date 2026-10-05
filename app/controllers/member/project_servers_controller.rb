# frozen_string_literal: true

module Member
  # Server collegati agli environment del progetto (multiselect della tab Environments). create =
  # sincronizza la lista COMPLETA di host (host_ids[]) per la coppia [progetto, environment] — gate
  # uptime.manage. Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects.
  class ProjectServersController < Member::BaseController
    before_action :set_project
    before_action :require_manage

    def create
      environment = @project.environments.find_by(id: params[:environment_id])
      if environment.nil?
        return redirect_to member_project_environments_path(@project),
                           alert: t("member.projects.show.servers_link_failed")
      end

      result = ::Servers::Links::SetHosts.call(project: @project, environment:,
                                               host_ids: params[:host_ids], actor: Current.account)
      if result.ok?
        redirect_to member_project_environments_path(@project), notice: t("member.projects.show.servers_updated")
      else
        redirect_to member_project_environments_path(@project), alert: result.error.message
      end
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_manage
      require_permission!("uptime.manage", scope: @project)
    end
  end
end
