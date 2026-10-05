# frozen_string_literal: true

module Api
  module V1
    module MetricGroups
      class SamplesController < Api::V1::BaseController
        before_action -> { require_scope!(:read) }

        def index
          group = Current.project.metric_groups.find(params[:metric_group_id])
          samples = group.samples.where(project_id: Current.project.id).order(occurred_at: :desc, id: :desc)
          records, meta = paginate(samples)
          render_ok(MetricSampleSerializer.new(records), meta:)
        end
      end
    end
  end
end
