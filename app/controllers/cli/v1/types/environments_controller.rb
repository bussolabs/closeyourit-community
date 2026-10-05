# frozen_string_literal: true

module Cli
  module V1
    module Types
      # Lookup environment dell'org del token (per i comandi CLI che li referenziano).
      class EnvironmentsController < Cli::V1::BaseController
        def index
          render_ok(EnvironmentSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :environments)
          ))
        end
      end
    end
  end
end
