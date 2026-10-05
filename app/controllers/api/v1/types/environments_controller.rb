# frozen_string_literal: true

module Api
  module V1
    module Types
      # Lookup environment dell'organizzazione del token (contratto client rules/lookup-tables.md).
      class EnvironmentsController < Api::V1::BaseController
        def index
          render_ok(EnvironmentSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :environments)
          ))
        end
      end
    end
  end
end
