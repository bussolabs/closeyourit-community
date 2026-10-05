# frozen_string_literal: true

module Cli
  module V1
    module Tokens
      module Provisions
        class RetriesController < Cli::V1::BaseController
          before_action :set_project!

          def create
            return unless require_permission!("tokens.manage", scope: @project)

            provision = @project.source_secret_provisions.find(params[:provision_id])
            return unless require_permission!("secrets.provision", scope: provision.destination_project)

            result = ::Secrets::Provisions::Retry.call(provision:, actor: Current.account)
            if result.ok?
              render json: { data: SecretProvisionSerializer.new(result.value).as_json }, status: :accepted
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end
        end
      end
    end
  end
end
