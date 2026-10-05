# frozen_string_literal: true

module Member
  module Monitoring
    class MeasurementsController < Member::BaseController
      include Member::MeasurementReading
      include Indexable
      permission_not_required "Measurements are read-only and scoped to visible projects."
      SORT_COLUMNS = { "name" => "LOWER(measurements_series.name)", "type" => :metric_type, "unit" => :unit, "observed" => "(SELECT MAX(p.time_unix_nano) FROM measurements_points p WHERE p.series_id = measurements_series.id AND p.project_id = measurements_series.project_id)" }.freeze
      remembers_filters :q, :project_id, :service_name, :environment, :attribute_scope, :attribute_key, :attribute_type, :attribute_value, :sort, only: :index, exact_keys: %i[service_name environment attribute_key attribute_value]
      helper_method :measurement_range

      def index
        @has_records = measurement_scope.exists?
        raise ::Measurements::Series::Query::Invalid, "Too many project filters" if filter_ids(:project_id).size > 200
        @projects = visible.projects.in_order_of(:id, filter_ids(:project_id), filter: false).order(:name, :id).limit(200).to_a
        @saved_views = bounded_records(saved_views_for("measurement_series").limit(100))
        scope = measurement_scope
        scope = scope.where(project_id: filter_ids(:project_id)) if filter_ids(:project_id).any?
        scope = scope.where("measurements_series.name ILIKE ?", "%#{ApplicationRecord.sanitize_sql_like(search_q)}%") if search_q.present?
        scope = ::Measurements::Series::Query.call(scope: scope, filters: typed_filters).reorder(Arel.sql("LOWER(measurements_series.name)"), :id)
        @pagination = page_records(sorted(scope, columns: SORT_COLUMNS).order(id: :desc))
        @series = @pagination.records
        @row_projects = visible.projects.where(id: @series.map(&:project_id)).index_by(&:id)
        latest = ::Measurements::Point.where(project_id: visible.projects.select(:id), series_id: @series.map(&:id))
          .select("DISTINCT ON (series_id) measurements_points.id").order(:series_id, time_unix_nano: :desc, start_time_unix_nano: :desc, id: :desc)
        @latest = bounded_records(::Measurements::Point.where(id: latest)).index_by(&:series_id)
        measurement_page
      end

      def show
        @series = bounded_record(measurement_scope.where(id: params[:id]))
        @project = visible.projects.find(@series.project_id)
        choices = ::Alerting::Measurements::Configuration::STATISTICS.fetch(@series.metric_type)
        @statistic = params[:statistic].presence || choices.first
        raise ::Measurements::Aggregation::Query::Invalid, "Invalid statistic" unless choices.include?(@statistic)
        @quantile = params[:quantile].presence || "0.95"
        @interval = params[:interval_seconds].presence || [ ((measurement_range.to - measurement_range.from) / 100).ceil, 60 ].max
        @aggregation = ::Measurements::Aggregation::Query.call(series: @series, from: measurement_range.from.iso8601(9), to: measurement_range.to.iso8601(9),
          interval_seconds: @interval, quantiles: @statistic == "percentile" ? [ @quantile ] : [])
        @buckets = @aggregation.fetch(:buckets)
        @pagination = Pagination.from_array(@buckets, page: params[:page], per: requested_per(Pagination::DEFAULT_PER))
        @rules = bounded_records(Current.organization.alerting_rules.where(project_id: @project.id, measurement_series_id: @series.id, event_type: :measurement_threshold).order(:name, :id).limit(20))
        measurement_page
      end

      private

      def measurement_range
        @measurement_range ||= begin
          validate_measurement_bounds!
          range = ::Monitoring::TimeRange.resolve(key: params[:range], from: params[:from], to: params[:to])
          raise ::Measurements::Aggregation::Query::Invalid, "Both custom bounds are required" if range.custom? && (!range.from || !range.to)
          raise ::Measurements::Aggregation::Query::Invalid, "Invalid custom bounds" if [ :from, :to ].any? { |key| params[key].present? && !::Monitoring::TimeRange.parse(params[key]) }
          ::Monitoring::TimeRange.new(key: range.key, from: range.from, to: range.to || Time.current)
        end
      end

      def validate_measurement_bounds!
        values = params.values_at(:from, :to)
        return if values.all?(&:blank?)
        raise ::Measurements::Aggregation::Query::Invalid, "Both custom bounds are required" unless values.all?(&:present?)
        values.each { |value| validate_measurement_timestamp!(value) }
        raise ArgumentError unless ::Monitoring::TimeRange.parse(values.first) < ::Monitoring::TimeRange.parse(values.last)
      rescue ArgumentError, TypeError
        raise ::Measurements::Aggregation::Query::Invalid, "Invalid custom bounds"
      end

      def validate_measurement_timestamp!(value)
        pattern = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})?\z/
        raise ArgumentError unless value.is_a?(String) && value.match?(pattern)
        if (offset = value.match(/([+-])(\d{2}):(\d{2})\z/))
          raise ArgumentError unless offset[2].to_i <= 23 && offset[3].to_i <= 59
        end
        date = Date._iso8601(value)
        raise ArgumentError unless Date.valid_date?(date[:year], date[:mon], date[:mday])
        raise ArgumentError unless date[:hour].between?(0, 23) && date[:min].between?(0, 59) && date.fetch(:sec, 0).between?(0, 59)
      end

      def typed_filters
        filters = params.permit(:service_name, :environment).to_h.reject { |_key, value| value.nil? || value == "" }
        return filters if params[:attribute_key].nil? || params[:attribute_key] == ""
        type, value = params.values_at(:attribute_type, :attribute_value)
        raise ArgumentError unless value.nil? || value.is_a?(String)
        value = case type
        when "stringValue", "intValue" then value.to_s
        when "doubleValue" then Float(value)
        when "boolValue"
          raise ArgumentError unless %w[true false].include?(value)
          value == "true"
        else raise ArgumentError
        end
        scope = { "resource" => "resource_attributes", "point" => "point_attributes" }.fetch(params[:attribute_scope])
        filters.merge(scope => [ { "key" => params[:attribute_key], "value" => { type => value } } ])
      rescue ArgumentError, TypeError, KeyError
        raise ::Measurements::Series::Query::Invalid, "Invalid typed filter"
      end
    end
  end
end
