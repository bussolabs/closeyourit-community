# frozen_string_literal: true

module Api
  module V1
    class MeasurementSeriesController < Api::V1::BaseController
      include OtlpReadBudget
      before_action -> { require_scope!(:read) }

      def index
        filters = params[:filters].presence || {}
        filters = { "name" => params[:name] } if params[:name].present? && filters == {}
        scope = ::Measurements::Series::Query.call(scope: Current.project.measurement_series, filters: filters)
        records, meta = paginate_bounded(scope)
        render_bounded(MeasurementSeriesSerializer.new(records), meta: meta)
      rescue ::Measurements::Series::Query::Invalid => error
        render_error("R422-MEASUREMENT-002", error.message, status: :unprocessable_content)
      end

      def show
        record = bounded_record(Current.project.measurement_series.where(id: params[:id]))
        render_bounded(MeasurementSeriesSerializer.new(record))
      end
    end
  end
end
