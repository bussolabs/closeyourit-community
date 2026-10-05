# frozen_string_literal: true

module Cli
  module V1
    module Types
      # Lookup stati ticket dell'org del token.
      class TicketStatusesController < Cli::V1::BaseController
        def index
          render_ok(TicketStatusSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :ticket_statuses)
          ))
        end
      end
    end
  end
end
