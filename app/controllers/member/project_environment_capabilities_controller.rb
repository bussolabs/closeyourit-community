# frozen_string_literal: true

module Member
  # Override di capability [servers/uptime/secrets] per un ambiente DICHIARATO dal progetto (tri-state:
  # eredita/on/off). Auto-save dallo switch della show del progetto (PATCH ottimistico JSON) con fallback
  # HTML no-JS. Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects
  # (model). :id = environment id; la riga join Connections::ProjectEnvironment si risolve da
  # [progetto, ambiente] → un environment non dichiarato o di un'altra org dà RecordNotFound (anti-BOLA).
  class ProjectEnvironmentCapabilitiesController < Member::BaseController
    before_action :set_project
    before_action :require_manage

    def update
      link = @project.project_environments.find_by!(environment_id: params[:id])
      if link.update(::Connections::ProjectEnvironment.capability_overrides(params))
        respond_to do |format|
          format.json { head :ok }
          format.html { redirect_to member_project_environments_path(@project), notice: t("member.projects.show.capability_updated") }
        end
      else
        respond_to do |format|
          format.json { head :unprocessable_content }
          format.html { redirect_to member_project_environments_path(@project), alert: link.errors.full_messages.to_sentence }
        end
      end
    end

    private

    # Anti-BOLA: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_manage
      require_permission!("projects.edit", scope: @project)
    end
  end
end
