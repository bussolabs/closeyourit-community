# frozen_string_literal: true

module Api
  module V1
    module Leases
      class AcquisitionsController < BaseController
        def create
          payload = lease_params
          result = ::Agents::Leases::Acquire.call(
            organization: Current.organization,
            holder: ::Agents::Leases::Holder.host(Current.agent_host),
            ticket_reference: payload[:ticket],
            params: payload
          )
          return render_lease_error(result.error) if result.err?

          outcome = result.value
          render_lease(outcome.lease, status: outcome.fresh_acquisition ? :created : :ok)
        end
      end
    end
  end
end
