# frozen_string_literal: true

module Member
  # Tab Environments del progetto (CYRA-63): posto unico per gestire gli environment. Tabella con una
  # riga per environment dell'org — dichiarazione (attiva/disattiva su questo progetto), capability
  # tri-state (riusa Member::ProjectEnvironmentCapabilitiesController) e multiselect server (riusa
  # Member::ProjectServersController). La panoramica del progetto resta in sola lettura.
  #
  # Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects (model),
  # come ProjectTokensController. :id = environment id; la riga join Connections::ProjectEnvironment si
  # risolve da [progetto, ambiente]. Gate projects.edit (gestione), scoping anti-BOLA all'org.
  class ProjectEnvironmentsController < Member::BaseController
    before_action :set_project
    before_action :require_edit

    def index
      @stats = @project.ticket_tally
      @environments = Current.organization.environments.active.ordered.to_a
      # Righe join dichiarate, indicizzate per environment_id: presenza = dichiarato; il valore è il
      # link capability (tri-state risolto) per il partial _environment_capabilities.
      @declared = @project.project_environments.includes(:environment).index_by(&:environment_id)
      @token_counts = @project.tokens.active.group(:environment_id).count

      # Server e monitor uptime esistono solo su progetti uptime-capable (stesso gate di Uptime::Monitor);
      # entrambi sono gestiti col permesso uptime.manage. @uptime_monitors alimenta l'accesso contestuale
      # alla creazione monitor (link "aggiungi monitor") — la creazione vive in Monitoring.
      @supports_uptime = @project.supports_uptime?
      @can_manage_uptime = can?("uptime.manage", scope: @project)
      if @supports_uptime
        @server_links = @project.server_links.includes(:host).to_a
                                .sort_by { |link| link.host.name }.group_by(&:environment_id)
        @linkable_hosts = @can_manage_uptime ? Current.organization.server_hosts.active.ordered.to_a : []
        @uptime_monitors = @project.uptime_monitors.includes(:environment).index_by(&:environment_id)
      else
        @server_links = {}
        @linkable_hosts = []
        @uptime_monitors = {}
      end
    end

    # Dichiara (attiva) un environment sul progetto: crea la riga join. Idempotente (doppio submit).
    def create
      environment = Current.organization.environments.active.find_by(id: params[:environment_id])
      if environment.nil?
        return redirect_to member_project_environments_path(@project),
                           alert: t("member.projects.environments.activate_failed")
      end

      @project.project_environments.find_or_create_by!(environment:)
      redirect_to member_project_environments_path(@project), notice: t("member.projects.environments.activated")
    end

    # Rimuove (disattiva) la dichiarazione dell'environment. Scoped al progetto → id non dichiarato o di
    # un'altra org è già invisibile (find_by anti-BOLA). I token/monitor/server legati restano orfani,
    # coerentemente con Projects::Save (rimuovere un environment_id dalla lista non li tocca).
    def destroy
      link = @project.project_environments.find_by(environment_id: params[:id])
      link&.destroy
      redirect_to member_project_environments_path(@project), notice: t("member.projects.environments.deactivated")
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_edit
      require_permission!("projects.edit", scope: @project)
    end
  end
end
