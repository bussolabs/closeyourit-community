# frozen_string_literal: true

module Api
  module V1
    module ErrorGroups
      class EventsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        rescue_from ::Artifacts::Rejected do |error|
          render_error("R422-SYMBOLICATION-001", error.message, status: :unprocessable_content)
        end

        def index
          group = Current.project.error_groups.find(params[:error_group_id])
          events = group.events.where(project_id: Current.project.id).order(occurred_at: :desc, id: :desc)
          records, meta = paginate_bounded(events)
          render_bounded(ErrorEventSerializer.new(records, params: { symbolications: ::Errors::Symbolication::Read.call(events: records) }), meta: meta)
        end
      end
    end
  end
end
