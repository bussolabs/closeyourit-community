# frozen_string_literal: true

module Artifacts
  module SourceMaps
    class Lookup < ApplicationService
      def initialize(map:, line:, column:)
        @map, @line, @column = map, line, column
      end

      def call
        target = [ @line, @column ]
        segments = @map.fetch("segments")
        next_index = segments.bsearch_index { |row| (row.first(2) <=> target).positive? } || segments.size
        return nil if next_index.zero?
        row = segments[next_index - 1]
        return nil if row[0] != @line || row.size == 2 || @map.fetch("sources")[row[2]].nil?
        original = { "filename" => @map.fetch("sources")[row[2]], "lineno" => row[3] + 1, "colno" => row[4] + 1 }
        position = row[3, 2]
        candidates = @map.fetch("functions").select do |range|
          range["source_index"] == row[2] &&
            (range.values_at("start_line", "start_column") <=> position) <= 0 &&
            (position <=> range.values_at("end_line", "end_column")) < 0
        end
        function = candidates.max_by { |range| [ range["start_line"], range["start_column"], -range["end_line"], -range["end_column"] ] }
        original["function"] = function && function["name"]
        { "original" => original, "mapped_name" => row.size == 6 ? @map.fetch("names")[row[5]] : nil }
      end
    end
  end
end
