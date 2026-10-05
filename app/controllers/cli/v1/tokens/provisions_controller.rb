# frozen_string_literal: true

module Cli
  module V1
    module Tokens
      # Distribuzione blind di un token: il server genera il valore e lo scrive nel vault senza
      # includerlo nella risposta. Il percorso reveal-once resta in Cli::V1::TokensController.
      class ProvisionsController < Cli::V1::BaseController
        PRODUCTION_CODES = %w[production prod prd].freeze

        before_action :set_project!
        before_action :require_source_permission

        def create
          destination = visible_projects.find(destination_params[:project_id])
          return unless require_permission!("secrets.provision", scope: destination)

          source_environment = resolve_environment(@project, params[:environment_id])
          destination_environment = resolve_environment(destination, destination_params[:environment_id])
          return render_invalid_environment unless source_environment && destination_environment
          return render_production_confirmation if production?(source_environment, destination_environment) && !confirmed?

          result = ::Projects::Tokens::Provision.call(
            source_project: @project, source_environment:, destination_project: destination,
            destination_environment:, name: params[:name], secret_name: destination_params[:secret_name],
            scopes: params[:scopes].presence || [ "ingest" ], idempotency_key: params[:idempotency_key],
            sync_github: sync_github?, created_by: Current.account, host: request.host
          )

          return render_payload(result.value, status: :created) if result.ok?

          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end

        def show
          provision = @project.source_secret_provisions.find(params[:id])
          return unless require_permission!("secrets.provision", scope: provision.destination_project)
          return render_forbidden_environment unless environment_allowed?(@project, provision.source_environment) &&
                                                    environment_allowed?(provision.destination_project, provision.destination_environment)

          render_payload(provision)
        end

        private

        def require_source_permission
          require_permission!("tokens.manage", scope: @project)
        end

        def destination_params
          @destination_params ||= params.require(:destination).permit(:project_id, :environment_id, :secret_name)
        end

        def resolve_environment(project, reference)
          ref = reference.to_s.strip
          project.environments.find_by(id: ref) || project.environments.find_by(code: ref.downcase)
        end

        def environment_allowed?(project, environment)
          ::Secrets::EnvironmentAccess.new(account: Current.account, project:).allowed?(environment.code)
        end

        def production?(*environments)
          environments.any? { |environment| PRODUCTION_CODES.include?(environment.code) }
        end

        def confirmed?
          ActiveModel::Type::Boolean.new.cast(params[:confirm_production])
        end

        def sync_github?
          return true unless params.key?(:sync_github)

          ActiveModel::Type::Boolean.new.cast(params[:sync_github])
        end

        def render_invalid_environment
          render_error("R422-PROVISION-002", I18n.t("provisions.errors.invalid_environment"),
                       status: :unprocessable_content)
        end

        def render_forbidden_environment
          render_error("R403-PROVISION-001", "Environment non consentito per questo account", status: :forbidden)
        end

        def render_production_confirmation
          render_error("R422-PROVISION-003", "Conferma production richiesta", status: :unprocessable_content)
        end

        def render_payload(provision, status: :ok)
          render json: {
            data: {
              token: ProjectTokenSerializer.new(provision.token).as_json,
              provision: SecretProvisionSerializer.new(provision).as_json
            }
          }, status:
        end
      end
    end
  end
end
