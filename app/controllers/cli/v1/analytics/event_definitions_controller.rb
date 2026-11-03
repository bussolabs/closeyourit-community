# frozen_string_literal: true

module Cli
  module V1
    module Analytics
      # Declared events of an analytics project (CLI channel, CYRA-1158). Same boundary and services as
      # the member page: visible and analytics-collecting project, otherwise R404. Updates are partial.
      class EventDefinitionsController < Cli::V1::BaseController
        before_action :set_project
        before_action :set_definition, only: %i[update destroy]

        def index
          render_ok(AnalyticsEventDefinitionSerializer.new(@project.analytics_event_definitions.ordered))
        end

        def create
          save(nil, :render_created)
        end

        def update
          save(@definition, :render_ok)
        end

        def destroy
          ::Analytics::EventDefinitions::Delete.call(definition: @definition)
          render_no_content
        end

        private

        def save(definition, renderer)
          result = ::Analytics::EventDefinitions::Save.call(project: @project, definition:, attributes: definition_params)
          if result.ok?
            send(renderer, AnalyticsEventDefinitionSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def set_project
          @project = visible_projects.analytics_collecting.find(params[:project_id])
        end

        def set_definition
          @definition = @project.analytics_event_definitions.find(params[:id])
        end

        def definition_params
          params.permit(:name, :property_names, property_names: [])
        end
      end
    end
  end
end
