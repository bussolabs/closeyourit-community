# frozen_string_literal: true

module Api
  module V1
    module Leases
      class ReleasesController < BaseController
        def create
          result = ::Agents::Leases::Release.call(
            organization: Current.organization,
            holder: ::Agents::Leases::Holder.host(Current.agent_host),
            ticket_reference: request.path_parameters[:ticket],
            params: lease_params
          )
          return render_lease_error(result.error) if result.err?

          render json: { data: { released: true } }
        end
      end
    end
  end
end
