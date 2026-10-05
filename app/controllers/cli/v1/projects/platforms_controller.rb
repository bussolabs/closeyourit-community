# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Dichiara le piattaforme del progetto da terminale (pendant del multi-select nella pagina
      # progetto member; speculare a Projects::EnvironmentsController). SET completo: l'elenco passato
      # sostituisce quello dichiarato. Accetta `codes[]` (es. web) e/o `platform_ids[]` (UUID).
      # Gate projects.edit; anti-BOLA via set_project!. Sblocca i monitor uptime (che esigono una
      # piattaforma web/server dichiarata).
      class PlatformsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :require_projects_edit

        def update
          @project.platform_ids = resolved_platform_ids
          render_ok(PlatformSerializer.new(@project.platforms.active.ordered))
        end

        private

        def require_projects_edit
          require_permission!("projects.edit", scope: @project)
        end

        # Risolve le piattaforme dell'organizzazione da codes e/o UUID. Scoping su
        # Current.organization.platforms = nessuna piattaforma di altri tenant può entrare.
        def resolved_platform_ids
          org = Current.organization.platforms
          by_id   = org.where(id: Array(params[:platform_ids]).reject(&:blank?)).ids
          by_code = org.where(code: Array(params[:codes]).reject(&:blank?)).ids
          (by_id + by_code).uniq
        end
      end
    end
  end
end
