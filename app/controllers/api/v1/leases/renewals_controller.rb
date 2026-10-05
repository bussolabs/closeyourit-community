# frozen_string_literal: true

module Api
  module V1
    module Leases
      class RenewalsController < BaseController
        def create
          result = ::Agents::Leases::Renew.call(
            organization: Current.organization,
            holder: ::Agents::Leases::Holder.host(Current.agent_host),
            ticket_reference: request.path_parameters[:ticket],
            params: lease_params
          )
          return render_lease_error(result.error) if result.err?

          render_lease(result.value)
        end
      end
    end
  end
end
