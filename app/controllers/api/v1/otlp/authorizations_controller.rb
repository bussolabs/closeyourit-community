# frozen_string_literal: true

module Api
  module V1
    module Otlp
      # The Collector authenticates before admitting an export to durable storage.
      class AuthorizationsController < Api::V1::BaseController
        before_action -> { require_scope!(:ingest) }

        def create
          render_ok({ organization_id: Current.organization.id, project_id: Current.project.id })
        end
      end
    end
  end
end
