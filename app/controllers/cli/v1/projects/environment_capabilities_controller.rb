# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Override di capability [servers/uptime/secrets] per un ambiente DICHIARATO dal progetto, da
      # terminale (pendant CLI degli switch nella show member). Tri-state: inherit|on|off per capability.
      # :environment_id = code o UUID, risolto SOLO tra gli ambienti dichiarati dal progetto (fuori scope
      # → R404). Gate projects.edit; anti-BOLA via set_project!.
      class EnvironmentCapabilitiesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :require_projects_edit

        def update
          link = @project.project_environments.find_by!(environment_id: resolve_environment!.id)
          link.update!(::Connections::ProjectEnvironment.capability_overrides(params))
          render_ok(ProjectEnvironmentSerializer.new(link))
        end

        private

        def require_projects_edit
          require_permission!("projects.edit", scope: @project)
        end

        # Ambiente tra quelli DICHIARATI dal progetto (l'override vive sulla join): id-OR-code, come
        # Cli::V1::EnvironmentsController. Un code non-UUID casta la colonna uuid a nil → no match (no 500).
        def resolve_environment!
          scope = @project.environments
          env = scope.find_by(id: params[:environment_id]) || scope.find_by(code: params[:environment_id])
          raise ActiveRecord::RecordNotFound unless env

          env
        end
      end
    end
  end
end
