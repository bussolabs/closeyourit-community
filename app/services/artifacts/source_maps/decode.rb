# frozen_string_literal: true

require "strscan"

module Artifacts
  module SourceMaps
    class Decode < ApplicationService
      def initialize(map:)
        @map = map
        @result = { "version" => 1, "sources" => [], "names" => [], "segments" => [], "functions" => [] }
        @sections = 0
      end

      def call
        raise Rejected, "source_map_too_large" if @map.to_json.bytesize > MAX_REQUEST
        decode(@map, line: 0, column: 0, depth: 0)
        validate_function_nesting!
        coalesce_segments!
        raise Rejected, "normalized_map_too_large" if @result.to_json.bytesize > MAX_MAP
        @result
      end

      private

      def coalesce_segments!
        @result["segments"] = @result["segments"].sort_by { |row| row.first(2) }.each_with_object([]) do |row, merged|
          previous = merged.last
          if previous && previous.first(2) == row.first(2)
            raise Rejected, "ambiguous_generated_position" unless previous.first(5) == row.first(5)
            names = [ previous[5], row[5] ].compact.uniq
            # Keep index identity: privacy filtering can make distinct names look equal.
            raise Rejected, "ambiguous_generated_position" if names.size > 1
            merged[-1] = row.first(5) + names
          else
            merged << row
          end
        end
      end

      def decode(map, line:, column:, depth:)
        raise Rejected, "invalid_source_map" unless map.is_a?(Hash) && map["version"] == 3
        raise Rejected, "source_map_depth" if depth > MAX_DEPTH
        if map.key?("sections")
          sections(map, line: line, column: column, depth: depth)
        else
          flat(map, line: line, column: column)
        end
      end

      def sections(map, line:, column:, depth:)
        items = map["sections"]
        raise Rejected, "invalid_sections" unless items.is_a?(Array) && !map.key?("mappings")
        previous = nil
        items.each do |section|
          @sections += 1
          raise Rejected, "section_budget" if @sections > MAX_SECTIONS
          position = section_position(section)
          raise Rejected, "overlapping_sections" if previous && (position <=> previous) <= 0
          generated = [ line + position[0], position[1] + (position[0].zero? ? column : 0) ]
          last = @result["segments"].max_by { |row| row.first(2) }&.first(2)
          raise Rejected, "overlapping_sections" if last && (generated <=> last) <= 0
          decode(section["map"], line: generated[0], column: generated[1], depth: depth + 1)
          previous = position
        end
      end

      def section_position(section)
        raise Rejected, "external_section" unless section.is_a?(Hash) && section["map"].is_a?(Hash) && !section.key?("url")
        offset = section["offset"]
        raise Rejected, "invalid_section_offset" unless offset.is_a?(Hash)
        [ coordinate(offset["line"]), coordinate(offset["column"]) ]
      end

      def flat(map, line:, column:)
        sources = strings(map["sources"], MAX_SOURCES, nullable: true)
        names = strings(map.fetch("names", []), MAX_NAMES)
        root = map["sourceRoot"]
        raise Rejected, "invalid_source_root" unless root.nil? || (root.is_a?(String) && root.valid_encoding? && root.bytesize <= 4096 && !root.include?("\0"))
        source_base, name_base = @result["sources"].size, @result["names"].size
        raise Rejected, "source_budget" if source_base + sources.size > MAX_SOURCES
        raise Rejected, "name_budget" if name_base + names.size > MAX_NAMES
        @result["sources"].concat(sources.map { |value| source_name(root, value) })
        @result["names"].concat(names.map { |value| scrub(value) })
        functions(map["x_closeyourit_functions"], sources.size, source_base)
        mappings(map["mappings"], sources.size, names.size, source_base, name_base, line, column)
      end

      def mappings(encoded, source_count, name_count, source_base, name_base, offset_line, offset_column)
        raise Rejected, "invalid_mappings" unless encoded.is_a?(String)
        scanner = StringScanner.new(encoded)
        generated_line = generated_column = source = original_line = original_column = name = 0
        until scanner.eos?
          segment = scanner.scan(/[^,;]*/)
          unless segment.empty?
            values = Vlq.decode(segment)
            generated_column = coordinate(generated_column + values[0])
            row = [ coordinate(offset_line + generated_line), coordinate(generated_column + (generated_line.zero? ? offset_column : 0)) ]
            if values.size > 1
              source += values[1]
              original_line = coordinate(original_line + values[2])
              original_column = coordinate(original_column + values[3])
              raise Rejected, "source_index" unless (0...source_count).cover?(source)
              row.concat([ source_base + source, original_line, original_column ])
            end
            if values.size == 5
              name += values[4]
              raise Rejected, "name_index" unless (0...name_count).cover?(name)
              row << name_base + name
            end
            @result["segments"] << row
            raise Rejected, "segment_budget" if @result["segments"].size > MAX_SEGMENTS
          end
          delimiter = scanner.getch
          if delimiter == ";"
            generated_line = coordinate(generated_line + 1)
            generated_column = 0
          end
        end
      end

      def functions(extension, source_count, source_base)
        return if extension.nil?
        raise Rejected, "invalid_functions" unless extension.is_a?(Hash) && extension["version"] == 1 && extension["ranges"].is_a?(Array)
        extension["ranges"].each do |range|
          raise Rejected, "invalid_function_range" unless range.is_a?(Hash)
          index = coordinate(range["source_index"])
          raise Rejected, "function_source_index" unless index < source_count
          start = [ coordinate(range["start_line"]), coordinate(range["start_column"]) ]
          finish = [ coordinate(range["end_line"]), coordinate(range["end_column"]) ]
          raise Rejected, "invalid_function_range" unless (finish <=> start).positive?
          name = range["name"]
          raise Rejected, "invalid_function_name" unless name.nil? || (name.is_a?(String) && name.present? && name.bytesize <= 512)
          @result["functions"] << { "source_index" => source_base + index, "start_line" => start[0], "start_column" => start[1], "end_line" => finish[0], "end_column" => finish[1], "name" => scrub(name) }
          raise Rejected, "function_budget" if @result["functions"].size > MAX_FUNCTIONS
        end
      end

      def validate_function_nesting!
        @result["functions"].group_by { |range| range["source_index"] }.each_value do |ranges|
          stack = []
          ranges.sort_by { |range| [ range["start_line"], range["start_column"], -range["end_line"], -range["end_column"] ] }.each do |range|
            start = range.values_at("start_line", "start_column")
            finish = range.values_at("end_line", "end_column")
            stack.pop while stack.any? && (start <=> stack.last.values_at("end_line", "end_column")) >= 0
            if stack.any?
              parent = stack.last
              raise Rejected, "crossing_function_ranges" if (finish <=> parent.values_at("end_line", "end_column")) > 0
              raise Rejected, "ambiguous_function_range" if start == parent.values_at("start_line", "start_column") && finish == parent.values_at("end_line", "end_column")
            end
            stack << range
            raise Rejected, "function_nesting_budget" if stack.size > 64
          end
        end
      end

      def coordinate(value)
        raise Rejected, "invalid_position" unless value.is_a?(Integer) && (0..MAX_POSITION).cover?(value)
        value
      end

      def strings(value, max, nullable: false)
        raise Rejected, "invalid_string_table" unless value.is_a?(Array) && value.size <= max
        value.each do |item|
          next if nullable && item.nil?
          raise Rejected, "invalid_string_table" unless item.is_a?(String) && item.valid_encoding? && item.bytesize <= 4096 && !item.include?("\0")
        end
        value
      end

      def source_name(root, value)
        return nil if value.nil?
        text = root.present? && !value.match?(/\A(?:[a-z][a-z0-9+.-]*:|\/)/i) ? "#{root.delete_suffix('/')}/#{value}" : value
        raise Rejected, "source_name_budget" if text.bytesize > 4096
        scrub(text)
      end

      def scrub(value) = Errors::Ingest::Scrub.call(payload: value)
    end
  end
end
