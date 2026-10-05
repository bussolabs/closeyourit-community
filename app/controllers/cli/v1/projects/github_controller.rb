# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Integrazione GitHub del progetto come sub-resource SINGLETON: stato connessione (show), aggancio
      # validato contro i repo visibili all'installazione (create) e regole di binding (update).
      # Parità col canale Member via i service condivisi
      # (Github::Repositories::Save, rules/backend-channels.md). Gate github.manage (scope progetto).
      # Anti-BOLA: progetto risolto in visible_projects (fuori scope / altra org → R404).
      class GithubController < Cli::V1::BaseController
        # sync_secrets NON è qui: accenderlo abilita la copia dei VALORI del vault verso GitHub, quindi è
        # un'impostazione a sé gated secrets.read (CYRA-234), non un flag di binding come gli altri.
        BOOLEAN_FLAGS = %w[sync_enabled tag_binding_enabled autoclose_on_merge].freeze

        before_action :set_project!
        before_action -> { require_permission!("github.manage", scope: @project) }

        def show
          render_ok(github_payload)
        end

        def create
          installation = @project.organization.github_installation
          if installation.nil?
            return render_error("R404-GITHUB-004", I18n.t("github.errors.no_installation"), status: :not_found)
          end

          full_name = params.require(:full_name).strip
          repository = ::Github::Client.new.repositories(installation.installation_id).find do |candidate|
            candidate["full_name"].to_s.casecmp?(full_name)
          end
          if repository.nil?
            return render_error("R404-GITHUB-002", I18n.t("github.errors.repo_not_available"), status: :not_found)
          end

          result = ::Github::Repositories::Connect.call(
            project: @project, repo_id: repository["id"], full_name: repository["full_name"],
            default_branch: repository["default_branch"]
          )
          if result.err?
            return render_error(result.error.code, result.error.message,
                                status: result.error.status, details: result.error.details)
          end

          render_created(github_payload)
        rescue ::Github::Client::Error => e
          render_error(e.code, e.message, status: e.status)
        end

        def update
          repository = @project.github_repository
          if repository.nil?
            return render_error("R404-GITHUB-002", I18n.t("github.errors.no_repo"), status: :not_found)
          end

          # Fail-closed: se la richiesta accende/spegne sync_secrets, rifiuta PRIMA di applicare qualunque
          # flag (CYRA-234) se manca secrets.read, o se l'attore è ristretto a un sottoinsieme di
          # environment (la sync è cross-environment: non può abilitarla, aggirerebbe il confine).
          if params.key?(:sync_secrets)
            return unless require_secrets_read
            return unless require_unrestricted_environments
          end

          apply_flags(repository)
          apply_sync_secrets(repository)
          if settings_requested? && (result = ::Github::Repositories::Save.call(repository:, attributes: settings_params)).err?
            return render_error(result.error.code, result.error.message,
                                status: result.error.status, details: result.error.details)
          end

          render_ok(github_payload)
        end

        private

        # Flag booleani senza validazioni → update_column (come i feature-flag). Solo quelli presenti.
        def apply_flags(repository)
          BOOLEAN_FLAGS.each do |flag|
            next unless params.key?(flag)

            repository.update_column(flag, ActiveModel::Type::Boolean.new.cast(params[flag]))
          end
        end

        # sync_secrets a sé: applicato solo se presente e SOLO dopo il gate secrets.read (già passato in update).
        def apply_sync_secrets(repository)
          return unless params.key?(:sync_secrets)

          repository.update_column(:sync_secrets, ActiveModel::Type::Boolean.new.cast(params[:sync_secrets]))
        end

        # secrets.read: gate della copia dei VALORI verso GitHub. CYRA-721 — `secrets.manage` non basta
        # più: gestire un valore non è vederlo, e la sync lo scrive fuori dal vault. Nega R403 e false.
        def require_secrets_read
          return true if authorization.can?("secrets.read", scope: @project)

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        # CYRA-234 — sync_secrets abilita una copia cross-environment (tutti gli slot mappati): un attore
        # ristretto a un sottoinsieme di environment non può accenderla. Nessuna restrizione = ok.
        def require_unrestricted_environments
          return true unless secret_access.restricted?

          render_error("R403-SECRET-001", "environment non consentito per questo account", status: :forbidden)
          false
        end

        # Confine ambienti dell'attore su questo progetto: policy condivisa (CYRA-78), override
        # per-progetto compreso. Vedi Secrets::EnvironmentAccess.
        def secret_access
          @secret_access ||= ::Secrets::EnvironmentAccess.new(account: Current.account, project: @project)
        end

        # CYRA-605 — `release_probe` va aggiunto anche QUI, non solo in `settings_params`: senza,
        # una richiesta che porta il solo campo nuovo risponde 200 e non cambia niente, perche' il
        # salvataggio non viene nemmeno tentato. E' il modo piu' silenzioso di non funzionare.
        def settings_requested?
          params.key?(:default_branch) || params.key?(:production_environment_id) ||
            params.key?(:staging_environment_id) || params.key?(:preview_environment_id) ||
            params.key?(:release_probe)
        end

        def settings_params
          params.permit(:default_branch, :production_environment_id, :staging_environment_id,
                        :preview_environment_id, :release_probe)
        end

        def github_payload
          repository = @project.github_repository
          {
            project_id: @project.id,
            installed: @project.organization.github_installation.present?,
            connected: repository.present?,
            repository: repository && repository_payload(repository)
          }
        end

        def repository_payload(repository)
          {
            full_name: repository.full_name,
            default_branch: repository.default_branch,
            sync_enabled: repository.sync_enabled,
            tag_binding_enabled: repository.tag_binding_enabled,
            autoclose_on_merge: repository.autoclose_on_merge,
            sync_secrets: repository.sync_secrets,
            production_environment_id: repository.production_environment_id,
            staging_environment_id: repository.staging_environment_id,
            preview_environment_id: repository.preview_environment_id,
            # NULL e' il terzo stato e va restituito com'e': «non ancora deciso» non e' «merge».
            release_probe: repository.release_probe
          }
        end
      end
    end
  end
end
