# frozen_string_literal: true

module Api
  module V1
    module Types
      # Lookup piattaforme dell'organizzazione del token (contratto client rules/lookup-tables.md).
      class PlatformsController < Api::V1::BaseController
        def index
          render_ok(PlatformSerializer.new(
            ::Types::Lookups::Query.call(organization: Current.organization, collection: :platforms)
          ))
        end
      end
    end
  end
end
