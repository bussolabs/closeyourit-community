# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Dichiara gli environment del progetto da terminale (il pendant CLI della striscia environment
      # nella pagina progetto member). SET completo: l'elenco passato sostituisce quello dichiarato.
      # Accetta `codes[]` (es. production) e/o `environment_ids[]` (UUID). Gate projects.edit; anti-BOLA
      # via set_project! (fuori scope → R404). Sblocca tokens#create (un token esige un env dichiarato).
      class EnvironmentsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :require_projects_edit

        def update
          @project.environment_ids = resolved_environment_ids
          render_ok(EnvironmentSerializer.new(@project.environments.active.ordered))
        end

        private

        def require_projects_edit
          require_permission!("projects.edit", scope: @project)
        end

        # Risolve gli environment dell'organizzazione da codes e/o UUID. Scoping su
        # Current.organization.environments = nessun environment di altri tenant può entrare.
        def resolved_environment_ids
          org = Current.organization.environments
          by_id   = org.where(id: Array(params[:environment_ids]).reject(&:blank?)).ids
          by_code = org.where(code: Array(params[:codes]).reject(&:blank?)).ids
          (by_id + by_code).uniq
        end
      end
    end
  end
end
