# frozen_string_literal: true

module Api
  module V1
    module MeasurementSeries
      class PointsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        def index
          series = bounded_record(Current.project.measurement_series.where(id: params[:measurement_series_id]))
          records, meta = paginate_bounded(series.points.order(:time_unix_nano, :start_time_unix_nano, :id))
          render_bounded(MeasurementPointSerializer.new(records), meta: meta)
        end
      end
    end
  end
end
