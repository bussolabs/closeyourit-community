# frozen_string_literal: true

module SessionHealth
  class Query < ApplicationService
    Invalid = Class.new(ArgumentError)
    COUNTERS = %w[exited errored unhandled crashed abnormal open anonymous].freeze

    def initialize(sessions:, aggregates:, release: nil, environment: nil, from: nil, to: nil, source: nil)
      @sessions = sessions
      @aggregates = aggregates
      @release, @environment, @source = release, environment, source
      raise Invalid, "Invalid session source" unless source.nil? || source.in?(%w[individual aggregate])
      @from, @to = parse_time(from), parse_time(to)
      raise Invalid, "Invalid time range" if @from && @to && @from > @to
    end

    def call(page: 1, per: 10, sort: nil)
      connection = ApplicationRecord.connection
      sql = summary_sql
      total = connection.select_value("SELECT COUNT(*) FROM (#{sql}) session_groups").to_i
      Pagination.from_query(total: total, page: page, per: per) do |offset, limit|
        connection.select_all("SELECT * FROM (#{sql}) session_groups ORDER BY #{ordering(sort)} LIMIT #{Integer(limit)} OFFSET #{Integer(offset)}").map { |row| decorate(row) }
      end
    end

    private

    SORT_COLUMNS = {
      "release" => "release", "source" => "source", "known" => "(exited + errored + unhandled + crashed)",
      "crashed" => "crashed", "unknown" => "(open + abnormal)",
      "rate" => "(exited + errored + unhandled)::numeric / NULLIF(exited + errored + unhandled + crashed, 0)"
    }.freeze

    def ordering(sort)
      raw = sort.to_s
      expression = SORT_COLUMNS[raw.delete_prefix("-")]
      primary = "#{expression} #{raw.start_with?("-") ? 'DESC' : 'ASC'} NULLS LAST, " if expression
      "#{primary}project_id, release, environment NULLS FIRST, source"
    end

    def summary_sql
      parts = []
      parts << individual_sql unless @source == "aggregate"
      parts << aggregate_sql unless @source == "individual"
      parts.join(" UNION ALL ")
    end

    def individual_sql
      counters = {
        exited: "status = 'exited' AND errors_count = 0", errored: "status = 'exited' AND errors_count > 0",
        unhandled: "status = 'unhandled'", crashed: "status = 'crashed'", abnormal: "status = 'abnormal'",
        open: "status = 'ok'", anonymous: "NOT producer_identity"
      }
      columns = counters.map { |key, predicate| "COUNT(*) FILTER (WHERE #{predicate}) AS #{key}" }
      grouped(@sessions).select(Arel.sql("project_id, release, environment, 'individual' AS source, #{columns.join(', ')}")).to_sql
    end

    def aggregate_sql
      columns = %w[exited errored unhandled crashed abnormal].map { |key| "SUM(#{key}) AS #{key}" }
      grouped(@aggregates).select(Arel.sql("project_id, release, environment, 'aggregate' AS source, #{columns.join(', ')}, 0 AS open, 0 AS anonymous")).to_sql
    end

    def grouped(scope)
      scope = scope.where(release: @release) if @release.present?
      scope = scope.where(environment: @environment) unless @environment.nil?
      scope = scope.where(started_at: @from..) if @from
      scope = scope.where(started_at: ..@to) if @to
      scope.group(:project_id, :release, :environment)
    end

    def decorate(row)
      values = COUNTERS.to_h { |key| [ key, row.fetch(key).to_i ] }
      numerator = values.values_at("exited", "errored", "unhandled").sum
      denominator = numerator + values.fetch("crashed")
      unknown = values.values_at("open", "abnormal").sum
      counts = values.merge("total" => denominator + unknown, "numerator" => numerator, "denominator" => denominator, "unknown" => unknown)
      row.merge(counts.transform_values(&:to_s)).merge(
        "crash_free_rate" => denominator.positive? ? numerator.fdiv(denominator) : nil,
        "deduplication" => row["source"] == "aggregate" ? "unavailable" : (values["anonymous"].positive? ? "partial" : "sid"),
        "denominator_definition" => "exited + errored + unhandled + crashed; open and abnormal excluded"
      )
    end

    def parse_time(value)
      return nil if value.blank?
      raise Invalid, "A timestamp with an explicit time zone is required" unless value.is_a?(String) && value.match?(Ingest::Decode::TIMESTAMP)
      DateTime.rfc3339(value)
      Time.iso8601(value).utc
    rescue ArgumentError
      raise Invalid, "Invalid timestamp"
    end
  end
end
