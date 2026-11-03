# frozen_string_literal: true

module Member
  module Monitoring
    module Analytics
      # Events of the period that are not in the project's declared list, each with a button that
      # declares it with the property names seen (CYRA-1158). Same boundary as the declared list.
      class UndeclaredEventsController < Member::BaseController
        permission_not_required "Eventi non dichiarati di un progetto visibile: come gli obiettivi, il confine è la " \
                                "visibilità del progetto."

        def index
          @project = visible.projects.analytics_collecting.find(params[:project_id])
          @range = ::Analytics::Pageview::BUCKETS.key?(params[:range]) ? params[:range] : ::Analytics::Pageview::DEFAULT_RANGE
          query = ::Analytics::Query.new(project_id: @project.id, range: @range)
          @events = query.undeclared_events(declared: @project.analytics_event_definitions.pluck(:name))
        end
      end
    end
  end
end
