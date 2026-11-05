# frozen_string_literal: true

module Member
  module Monitoring
    module Analytics
      # CRUD dei goal (conversioni) di un progetto analytics. Nessuna chiave RBAC: gestione = chi vede
      # lo scope (coerente con la dashboard analytics, read = visibilità). Anti-BOLA via lo scope
      # visibile+collecting (progetto non visibile / non analytics → 404). Model fully-qualified
      # (::Analytics::Goal) per non risolvere dentro Member::Monitoring::Analytics.
      class GoalsController < Member::BaseController
        permission_not_required "Obiettivi di un progetto visibile: come la dashboard del traffico, il confine è la " \
                                "visibilità del progetto."

        before_action :set_project
        before_action :set_goal, only: :destroy

        # CYRA-924 — goal and kind sort (C9).
        SORT_COLUMNS = { "goal" => "LOWER(analytics_goals.display_name)", "kind" => :kind }.freeze

        def index
          @goals = sorted(@project.analytics_goals.ordered, columns: SORT_COLUMNS)
        end

        def new
          @goal = @project.analytics_goals.new(kind: :pageview_path)
        end

        def create
          result = ::Analytics::Goals::Save.call(project: @project, attributes: goal_params)
          if result.ok?
            redirect_to goals_path, notice: t("member.monitoring.analytics.goals.created")
          else
            @goal = @project.analytics_goals.new(goal_params)
            @goal.valid?
            flash.now[:alert] = result.error.message
            render :new, status: :unprocessable_content
          end
        end

        def destroy
          ::Analytics::Goals::Delete.call(goal: @goal)
          redirect_to goals_path, notice: t("member.monitoring.analytics.goals.deleted")
        end

        private

        def goals_path
          member_monitoring_analytics_goals_path(project_id: @project.id)
        end

        def set_project
          @project = visible.projects.analytics_collecting.find(params[:project_id])
        end

        def set_goal
          @goal = @project.analytics_goals.find(params[:id])
        end

        def goal_params
          params.require(:analytics_goal).permit(:kind, :event_name, :path_pattern, :display_name)
        end
      end
    end
  end
end
