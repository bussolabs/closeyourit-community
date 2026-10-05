# frozen_string_literal: true

module Cli
  module V1
    module Tokens
      # Rotazione di una credenziale di ingest come risorsa singleton: PUT = emette un nuovo token e
      # revoca il vecchio (transazione). Gate tokens.manage. Rivela il nuovo segreto + DSN una volta.
      class RotationsController < Cli::V1::BaseController
        before_action :set_project!
        before_action -> { require_permission!("tokens.manage", scope: @project) }

        def update
          token = @project.tokens.find(params[:token_id])
          result = ::Projects::Tokens::Rotate.call(token:, host: request.host, created_by: Current.account)
          if result.ok?
            issued = result.value[:new]
            render json: {
              data: {
                token: ProjectTokenSerializer.new(issued[:token]).as_json,
                secret: issued[:secret],
                dsn: issued[:dsn],
                sentry_dsn: issued[:sentry_dsn]
              }
            }, status: :ok
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end
      end
    end
  end
end
