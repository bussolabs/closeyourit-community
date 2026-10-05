# frozen_string_literal: true

module Api
  module V1
    module Types
      class TicketPrioritiesController < Api::V1::BaseController
        def index
          render_ok(TicketPrioritySerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :ticket_priorities)
          ))
        end
      end
    end
  end
end
