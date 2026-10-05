# frozen_string_literal: true

module Cli
  module V1
    module Types
      # Lookup priorità ticket dell'org del token.
      class TicketPrioritiesController < Cli::V1::BaseController
        def index
          render_ok(TicketPrioritySerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :ticket_priorities)
          ))
        end
      end
    end
  end
end
