# frozen_string_literal: true

module Cli
  module V1
    # Environment (Types::Environment) dell'organizzazione del token: CRUD org-level. Lettura (index/show)
    # gated da `environments.view` (chi gestisce con `environments.manage` vede sempre);
    # create/update/destroy gated da `environments.manage` (org-level), identico al canale Member.
    # È il CRUD ORG-LEVEL, distinto da `cli/v1/types/environments#index` (lookup readonly) e da
    # `cli/v1/projects/:id/environments` (dichiarazione per-progetto). La logica è CRUD banale su model
    # (nessuna logica di dominio da estrarre).
    #
    # Anti-BOLA: scoping all'org via `org_environments`. set_environment risolve id-OR-code (la CLI passa
    # l'identifier — UUID o code — direttamente nel path): `find_by(id:)` con un code non-UUID casta la
    # colonna uuid a nil → nessun match (no 500) → si prova per code; nessuno dei due → R404.
    class EnvironmentsController < Cli::V1::BaseController
      before_action :require_environments_view, only: %i[index show]
      before_action :set_environment, only: %i[show update destroy]
      before_action :require_environments_management, only: %i[create update destroy]

      def index
        records, meta = paginate(org_environments.ordered)
        render_ok(EnvironmentSerializer.new(records), meta: meta)
      end

      def show
        render_ok(EnvironmentSerializer.new(@environment))
      end

      def create
        environment = org_environments.new(environment_params)
        environment.created_by = Current.account
        if environment.save
          render_created(EnvironmentSerializer.new(environment))
        else
          render_environment_error(environment)
        end
      end

      def update
        if @environment.update(environment_params)
          render_ok(EnvironmentSerializer.new(@environment))
        else
          render_environment_error(@environment)
        end
      end

      def destroy
        if @environment.destroy
          render_no_content
        else
          render_environment_error(@environment)
        end
      end

      private

      def set_environment
        @environment = org_environments.find_by(id: params[:id]) || org_environments.find_by(code: params[:id])
        raise ActiveRecord::RecordNotFound unless @environment
      end

      def org_environments
        Current.organization.environments
      end

      def environment_params
        params.permit(:code, :label, :color, :position, :active, :servers_enabled, :uptime_enabled, :secrets_enabled)
      end

      def render_environment_error(environment)
        render_error("R422-ENVIRONMENT-001", environment.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: environment.errors.to_hash)
      end

      # Lettura (index/show): gata da environments.view; chi gestisce (environments.manage) vede sempre.
      def require_environments_view
        require_permission!("environments.view") unless authorization.can?("environments.manage")
      end

      def require_environments_management
        require_permission!("environments.manage")
      end
    end
  end
end
