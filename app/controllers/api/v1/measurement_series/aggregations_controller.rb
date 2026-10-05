# frozen_string_literal: true

module Api
  module V1
    module MeasurementSeries
      class AggregationsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        def show
          series = bounded_record(Current.project.measurement_series.where(id: params[:measurement_series_id]))
          result = ::Measurements::Aggregation::Query.call(series: series, from: params[:from], to: params[:to], interval_seconds: params[:interval_seconds].presence || 60, quantiles: params[:quantiles] || [])
          render_bounded(result)
        rescue ::Measurements::Aggregation::Query::Invalid => error
          render_error("R422-MEASUREMENT-001", error.message, status: :unprocessable_content)
        end
      end
    end
  end
end
