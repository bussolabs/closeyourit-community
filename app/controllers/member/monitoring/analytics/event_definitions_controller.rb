# frozen_string_literal: true

module Member
  module Monitoring
    module Analytics
      # The project's declared events and their expected properties (CYRA-1158). Same boundary as the
      # goals: whoever sees the analytics project manages the list; anything else is a 404.
      class EventDefinitionsController < Member::BaseController
        permission_not_required "Eventi dichiarati di un progetto visibile: come gli obiettivi, il confine è la " \
                                "visibilità del progetto."

        before_action :set_project
        before_action :set_definition, only: %i[edit update destroy]

        SORT_COLUMNS = { "name" => "LOWER(analytics_event_definitions.name)" }.freeze

        def index
          @definitions = sorted(@project.analytics_event_definitions.ordered, columns: SORT_COLUMNS)
        end

        def new
          @definition = @project.analytics_event_definitions.new
        end

        def edit; end

        def create
          save(@project.analytics_event_definitions.new, :new, "created")
        end

        def update
          save(@definition, :edit, "updated")
        end

        def destroy
          ::Analytics::EventDefinitions::Delete.call(definition: @definition)
          redirect_to definitions_path, notice: t("member.monitoring.analytics.event_definitions.deleted")
        end

        private

        def save(definition, template, notice)
          result = ::Analytics::EventDefinitions::Save.call(project: @project, definition:, attributes: definition_params)
          return redirect_to(definitions_path, notice: t("member.monitoring.analytics.event_definitions.#{notice}")) if result.ok?

          @definition = definition
          flash.now[:alert] = result.error.message
          render template, status: :unprocessable_content
        end

        def definitions_path
          member_monitoring_analytics_event_definitions_path(project_id: @project.id)
        end

        def set_project
          @project = visible.projects.analytics_collecting.find(params[:project_id])
        end

        def set_definition
          @definition = @project.analytics_event_definitions.find(params[:id])
        end

        def definition_params
          params.require(:analytics_event_definition).permit(:name, :property_names)
        end
      end
    end
  end
end
