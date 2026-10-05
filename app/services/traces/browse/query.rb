# frozen_string_literal: true

module Traces
  module Browse
    class Query < ApplicationService
      SORTS = { "received" => "traces.last_received_at", "duration" => "observed.duration_ns", "spans" => "observed.span_count", "id" => "traces.trace_id" }.freeze
      FILTERS = %w[q service environment version status min_duration_ms max_duration_ms sort page per].freeze
      STATUS = "CASE WHEN COUNT(*) = 0 THEN 'unknown' WHEN BOOL_OR(status_code = 2) THEN 'error' WHEN BOOL_AND(status_code = 1) THEN 'ok' WHEN BOOL_AND(status_code = 0) THEN 'unset' ELSE 'mixed' END"

      def initialize(scope:, params: {})
        @scope, @params = scope, params.to_h.stringify_keys.slice(*FILTERS)
        @params.each { |key, value| raise Invalid, "Invalid trace filter" unless value.nil? || value.is_a?(String) || %w[page per].include?(key) && value.is_a?(Integer) }
      end

      def call
        relation = filtered
        order = ordering
        Budget.within do
          Pagination.from_query(total: relation.count(:all), page: @params["page"], per: @params["per"] || Pagination::DEFAULT_PER) do |offset, limit|
            relation.with_topology.select("traces.*", "observed.duration_ns AS observed_duration_ns", "observed.span_count AS observed_span_count", "observed.status AS observed_status",
              "observed.start_ns AS observed_start_ns", "observed.end_ns AS observed_end_ns", "observed.service_count AS observed_service_count",
              "ARRAY(SELECT DISTINCT LEFT(service_name, 128) FROM traces_spans services WHERE services.trace_record_id = traces.id AND service_name IS NOT NULL ORDER BY 1 LIMIT 20) AS observed_services", <<~SQL.squish)
                (SELECT LEFT(name, 256) FROM traces_spans title WHERE title.trace_record_id = traces.id
                  ORDER BY (parent_span_id IS NULL) DESC, start_time_unix_nano, span_id LIMIT 1) AS observed_name
              SQL
              .order(Arel.sql(order)).offset(offset).limit(limit).to_a
          end
        end
      end

      private

      def filtered
        relation = @scope.joins(<<~SQL.squish)
          CROSS JOIN LATERAL (SELECT COUNT(*) AS span_count, COUNT(DISTINCT service_name) AS service_count, MIN(start_time_unix_nano) AS start_ns,
            MAX(end_time_unix_nano) AS end_ns, MAX(end_time_unix_nano) - MIN(start_time_unix_nano) AS duration_ns,
            #{STATUS} AS status FROM traces_spans WHERE trace_record_id = traces.id) observed
        SQL
        matching = Span.where("traces_spans.trace_record_id = traces.id")
        matching = attributes(matching)
        if (query = @params["q"]).present?
          raise Invalid, "Search exceeds its limit" if query.bytesize > 256
          pattern = "%#{ApplicationRecord.sanitize_sql_like(query)}%"
          matching = matching.where("traces.trace_id ILIKE ? OR traces_spans.name ILIKE ?", pattern, pattern)
        end
        resources = @params.slice("service", "environment", "version").values.any? { |value| !value.nil? }
        if resources
          relation = relation.where("EXISTS (#{matching.select('1').to_sql})")
        elsif query.present?
          relation = relation.where("traces.trace_id ILIKE ? OR EXISTS (#{matching.select('1').to_sql})", pattern)
        end
        if (status = @params["status"]).present?
          raise Invalid, "Invalid observed status" unless %w[error ok unset mixed unknown].include?(status)
          relation = relation.where("observed.status = ?", status)
        end
        minimum, maximum = %w[min_duration_ms max_duration_ms].map { |key| duration(@params[key]) }
        raise Invalid, "Invalid duration interval" if minimum && maximum && minimum > maximum
        relation = relation.where("observed.duration_ns >= ?", minimum) if minimum
        relation = relation.where("observed.duration_ns <= ?", maximum) if maximum
        relation
      end

      def attributes(scope)
        { "service" => "service.name", "version" => "service.version" }.each do |param, key|
          scope = scope.where("resource @> ?::jsonb", attribute(key, @params[param])) unless @params[param].nil?
        end
        unless @params["environment"].nil?
          scope = scope.where("(resource @> ?::jsonb OR (NOT (resource @> ?::jsonb) AND resource @> ?::jsonb))",
            attribute("deployment.environment.name", @params["environment"]), { attributes: [ { key: "deployment.environment.name" } ] }.to_json,
            attribute("deployment.environment", @params["environment"]))
        end
        scope
      end

      def attribute(key, value)
        raise Invalid, "Invalid resource filter" unless value.is_a?(String) && value.bytesize <= 256
        { attributes: [ { key: key, value: { stringValue: value } } ] }.to_json
      end

      def duration(value)
        return nil if value.nil? || value == ""
        raise Invalid, "Invalid duration" unless value.is_a?(String) && value.match?(/\A\d{1,14}(?:\.\d{1,6})?\z/)
        BigDecimal(value) * 1_000_000
      end

      def ordering
        sort = @params["sort"].presence || "-received"
        direction = sort.start_with?("-") ? "DESC" : "ASC"
        column = SORTS[sort.delete_prefix("-")] || raise(Invalid, "Invalid trace sort")
        "#{column} #{direction} NULLS LAST, traces.id DESC"
      end
    end
  end
end
