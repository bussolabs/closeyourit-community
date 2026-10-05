# frozen_string_literal: true

module Api
  module V1
    module Servers
      class ActionClaimsController < Api::BaseController
        include HostAuthentication
        before_action :authenticate_host!

        def create
          action = ::Servers::Actions::Claim.call(host: Current.server_host).value
          return head :no_content unless action

          render json: { data: { id: action.id, kind: action.kind, expires_at: action.expires_at.iso8601 } }
        end
      end
    end
  end
end
