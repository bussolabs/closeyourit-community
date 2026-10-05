# frozen_string_literal: true

module Cli
  module V1
    module Types
      # Lookup piattaforme dell'org del token.
      class PlatformsController < Cli::V1::BaseController
        def index
          render_ok(PlatformSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :platforms)
          ))
        end
      end
    end
  end
end
