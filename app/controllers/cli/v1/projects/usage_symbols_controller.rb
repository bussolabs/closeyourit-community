# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # CYSK-29 — rilettura della telemetria d'uso: i simboli VISTI (l'insieme positivo). Il verdetto
      # «inutilizzato» non si calcola qui: richiede l'inventario statico, che vive nel repo, e lo
      # produce lo scanner. La visibilità del progetto è il gate, come le altre letture di progetto.
      class UsageSymbolsController < Cli::V1::BaseController
        before_action :set_project!

        def index
          scope = ::Usage::Symbol.where(project_id: @project.id).recent_first
          scope = scope.where(kind: params[:kind].to_s) if params[:kind].present?
          scope = scope.where(environment: params[:environment].to_s) if params[:environment].present?
          records, meta = paginate(scope)
          render_ok(::UsageSymbolSerializer.new(records), meta: meta)
        end
      end
    end
  end
end
