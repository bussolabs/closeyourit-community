# frozen_string_literal: true

module Cli
  module V1
    module Analytics
      # Goal di conversione della dashboard analytics di un progetto (canale CLI). Ungated: gestione =
      # chi vede lo scope (coerente con la dashboard analytics, read = visibilità). Anti-BOLA + parità
      # web: il progetto si risolve tra i visibili E analytics-collecting (piattaforma web + toggle attivo)
      # come Member::Monitoring::Analytics::GoalsController → progetto non visibile o non-collecting = R404.
      # Logica nei service condivisi Analytics::Goals::{Save,Delete}. Model fully-qualified (::Analytics::*).
      class GoalsController < Cli::V1::BaseController
        before_action :set_project

        def index
          render_ok(AnalyticsGoalSerializer.new(@project.analytics_goals.ordered))
        end

        def create
          result = ::Analytics::Goals::Save.call(project: @project, attributes: goal_params)
          if result.ok?
            render_created(AnalyticsGoalSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          goal = @project.analytics_goals.find(params[:id])
          ::Analytics::Goals::Delete.call(goal: goal)
          render_no_content
        end

        private

        def set_project
          @project = visible_projects.analytics_collecting.find(params[:project_id])
        end

        def goal_params
          params.permit(:kind, :event_name, :path_pattern, :display_name)
        end
      end
    end
  end
end
