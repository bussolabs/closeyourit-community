# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Guidance risolta del progetto (CYRA-74) come sub-resource SINGLETON in sola lettura. La visibilità
      # del progetto È il gate (chi vede il progetto vede il suo contesto): nessuna chiave RBAC dedicata,
      # come la show del progetto. Anti-BOLA: il progetto si risolve in visible_projects (fuori scope /
      # altra org → R404). La composizione org → gruppo → progetto e l'override vivono in Guidance::Resolve.
      class GuidanceController < Cli::V1::BaseController
        before_action :set_project!

        def show
          resolution = ::Guidance::Resolve.call(project: @project)
          render_ok(::Guidance::ResolutionSerializer.new(resolution))
        end
      end
    end
  end
end
