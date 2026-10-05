# frozen_string_literal: true

module Api
  module V1
    module Servers
      class ActionsController < Api::BaseController
        include HostAuthentication
        before_action :authenticate_host!

        def update
          action = Current.server_host.actions.find(params[:id])
          result = ::Servers::Actions::Complete.call(action:, status: params[:status], exit_code: params[:exit_code],
                                                     output: params[:output], error: params[:error], result: params[:result])
          return render_error(result.error.code, result.error.message, status: :unprocessable_content) unless result.ok?

          render json: { data: { accepted: true } }
        end
      end
    end
  end
end
