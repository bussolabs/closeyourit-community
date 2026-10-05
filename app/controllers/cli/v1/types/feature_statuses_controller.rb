# frozen_string_literal: true

module Cli
  module V1
    module Types
      # Lookup stati di una cella della matrice, dell'org del token. Solo gli ATTIVI: sono le scelte
      # possibili in scrittura, e la CLI li usa per suggerire i code di `matrix cells set`.
      class FeatureStatusesController < Cli::V1::BaseController
        def index
          render_ok(FeatureStatusSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :feature_statuses)
          ))
        end
      end
    end
  end
end
