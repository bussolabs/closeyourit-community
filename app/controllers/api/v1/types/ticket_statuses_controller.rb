# frozen_string_literal: true

module Api
  module V1
    module Types
      class TicketStatusesController < Api::V1::BaseController
        def index
          render_ok(TicketStatusSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :ticket_statuses)
          ))
        end
      end
    end
  end
end
