# frozen_string_literal: true

module Member
  # Integrazione GitHub del progetto (tab GitHub): aggancio repo 1:1, regole di binding tag→release
  # (mapping environment), toggle sync/tag_binding/autoclose in auto-save. Controller flat (non
  # Member::Projects::*) per non ombreggiare il namespace ::Github (model) nei controller. Scoping
  # anti-BOLA all'org, gate github.manage.
  class ProjectGithubController < Member::BaseController
    # sync_secrets NON è qui: accenderlo abilita la copia dei VALORI del vault verso GitHub, quindi è
    # un'impostazione a sé gated secrets.read (CYRA-234), non un flag di binding come gli altri.
    BOOLEAN_FLAGS = %w[sync_enabled tag_binding_enabled autoclose_on_merge].freeze

    before_action :set_project
    before_action :require_manage
    helper_method :secrets_readable?

    def show
      @repository = @project.github_repository
      @installation = @project.organization.github_installation
      @available_repos = available_repos if @repository.nil?
      @stats = @project.ticket_tally
    end

    def update
      @repository = @project.github_repository
      respond_to do |format|
        format.html { save_or_connect }
        format.json { toggle_flag } # switch via fetch (auto-save, no reload)
      end
    end

    def destroy
      @project.github_repository&.destroy
      redirect_to member_project_github_path(@project), notice: t("member.project_github.disconnected")
    end

    # Push sync on-demand ("Sync now"): enfila il job (che sincronizza gli slot mappati con sync_secrets on).
    # Gate secrets.read oltre a github.manage: lanciare la copia scrive i VALORI del vault (CYRA-234).
    def sync
      unless secrets_readable?
        return redirect_to member_project_github_path(@project), alert: t("member.forbidden")
      end

      repository = @project.github_repository
      if repository.nil?
        redirect_to member_project_github_path(@project), alert: t("member.project_github.sync_no_repo")
      else
        preflight = ::Secrets::Github::Preflight.call(repository:)
        if preflight.err?
          # CYRA-106 — l'avviso rosso sparisce al primo ricaricamento. L'esito invece resta scritto,
          # altrimenti subito dopo un tentativo bloccato la scheda tornerebbe a mostrare il "riuscito"
          # di ieri: il contrario di quello che è appena successo.
          repository.record_sync_failure!(preflight.error)
          return redirect_to member_project_github_path(@project),
                             alert: t("member.project_github.sync_blocked", code: preflight.error.code)
        end

        ::Secrets::Github::SyncJob.perform_later(github_repository_id: repository.id)
        redirect_to member_project_github_path(@project), notice: t("member.project_github.sync_enqueued")
      end
    end

    private

    # HTML: se il repo è già agganciato aggiorna le regole; altrimenti aggancia il repo scelto (il
    # full_name/default_branch si risolvono server-side dalla lista dell'installazione, non dal client).
    def save_or_connect
      result = @repository ? save_settings : connect_repo
      if result.ok?
        redirect_to member_project_github_path(@project), notice: t("member.project_github.saved")
      else
        render_show_error(result.error)
      end
    end

    def save_settings
      ::Github::Repositories::Save.call(repository: @repository, attributes: settings_params)
    end

    def connect_repo
      repo = available_repos.find { |r| r["id"].to_s == params[:repo_id].to_s }
      return Result.err(AppError.new(t("github.errors.repo_not_available"), code: "R404-GITHUB-002", status: :not_found)) if repo.nil?

      ::Github::Repositories::Connect.call(
        project: @project, repo_id: repo["id"], full_name: repo["full_name"], default_branch: repo["default_branch"]
      )
    end

    # JSON: toggla un singolo flag booleano con update_column (indipendente da colonne non correlate,
    # come i feature-flag del progetto). 204 senza body. sync_secrets è a sé: accenderlo abilita la
    # copia dei VALORI del vault verso GitHub → gate secrets.read (CYRA-234), altrimenti 403.
    def toggle_flag
      return head(:not_found) if @repository.nil?

      if params.key?(:sync_secrets)
        return head(:forbidden) unless secrets_readable?

        @repository.update_column(:sync_secrets, ActiveModel::Type::Boolean.new.cast(params[:sync_secrets]))
        return head(:no_content)
      end

      permitted = params.permit(*BOOLEAN_FLAGS)
      flag = BOOLEAN_FLAGS.find { |f| permitted.key?(f) }
      return head(:unprocessable_content) unless flag

      @repository.update_column(flag, ActiveModel::Type::Boolean.new.cast(permitted[flag]))
      head :no_content
    end

    # Può leggere i VALORI del vault del progetto? (manage implica read). Gata l'accensione e il lancio
    # della copia dei secret verso GitHub, e l'affordance relativa nella view.
    # CYRA-234 — gate della copia dei VALORI verso GitHub. CYRA-721: solo `secrets.read`. Gestire i
    # segreti non è vederli, e la sync li scrive fuori dal vault: se bastasse `secrets.manage`, chi non
    # può aprire una cella li porterebbe tutti su GitHub in un colpo solo.
    def secrets_readable?
      @secret_access ||= ::Secrets::EnvironmentAccess.new(account: Current.account, project: @project)
      can?("secrets.read", scope: @project) && !@secret_access.restricted?
    end

    def render_show_error(error)
      @error = error
      @installation = @project.organization.github_installation
      @available_repos = available_repos if @repository.nil?
      @stats = @project.ticket_tally
      render :show, status: error.status
    end

    # Repo dell'installazione dell'org (per il picker). Vuoto se l'org non ha connesso l'App o l'API
    # GitHub non risponde (il tab resta usabile, mostra la guida).
    def available_repos
      @available_repos ||= begin
        installation = @project.organization.github_installation
        installation ? ::Github::Client.new.repositories(installation.installation_id) : []
      rescue ::Github::Client::Error
        []
      end
    end

    def settings_params
      params.permit(:default_branch, :production_environment_id, :staging_environment_id,
                    :preview_environment_id, :release_probe, :registry, :package_name)
    end

    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_manage
      require_permission!("github.manage", scope: @project)
    end
  end
end
