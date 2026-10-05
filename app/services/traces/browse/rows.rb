# frozen_string_literal: true

module Traces
  module Browse
    class Rows < ApplicationService
      MAX_BYTES = 5.megabytes

      def initialize(scope:)
        @scope = scope
      end

      def call
        @scope.klass.columns_hash
        rows = @scope.connection.select_all(<<~SQL)
          SELECT total_bytes, CASE WHEN total_bytes <= #{MAX_BYTES} THEN row_data ELSE NULL END AS bounded_row
          FROM (SELECT to_jsonb(selected) AS row_data, SUM(octet_length(to_jsonb(selected)::text)) OVER () AS total_bytes
            FROM (#{@scope.to_sql}) selected) measured
        SQL
        raise Invalid, "Requested trace records exceed the page byte budget" if rows.any? { |row| row["total_bytes"].to_i > MAX_BYTES }
        rows.map do |row|
          value = row["bounded_row"]
          value = JSON.parse(value) if value.is_a?(String)
          @scope.klass.instantiate(value)
        end
      end
    end
  end
end
