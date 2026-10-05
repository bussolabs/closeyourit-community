# frozen_string_literal: true

module Errors
  class Symbolication
    module Dependencies
      KINDS = { "source_map" => "source_map_id", "proguard_map" => "proguard_map_id", "native_symbol" => "native_symbol_id" }.freeze
      module_function

      def call(result:)
        entries = result.fetch("dependencies", [])
        raise ::Artifacts::Rejected, "invalid_artifact_dependencies" unless entries.is_a?(Array) && entries.size <= 500
        entries = entries + frame_dependencies(result)
        entries.uniq!
        raise ::Artifacts::Rejected, "invalid_artifact_dependencies" unless entries.size <= 500
        entries.map do |entry|
          unless entry.is_a?(Hash) && entry.keys.sort == %w[id kind] && KINDS.key?(entry["kind"]) && entry["id"].is_a?(String) && entry["id"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
            raise ::Artifacts::Rejected, "invalid_artifact_dependencies"
          end
          entry
        end.uniq
      end

      def frame_dependencies(result)
        %w[frames groups].flat_map do |field|
          frames = result.fetch(field, [])
          raise ::Artifacts::Rejected, "invalid_artifact_dependencies" unless frames.is_a?(Array) && frames.size <= 500
          frames.filter_map do |frame|
            unless frame.is_a?(Hash) && (!frame.key?("artifact_kind") || KINDS.key?(frame["artifact_kind"]))
              raise ::Artifacts::Rejected, "invalid_artifact_dependencies"
            end
            { "kind" => frame.fetch("artifact_kind", "source_map"), "id" => frame["artifact_id"] } if frame["artifact_id"]
          end
        end.uniq
      end

      def model(kind)
        case kind
        when "source_map" then ::Artifacts::SourceMap
        when "proguard_map" then ::Artifacts::ProguardMap
        when "native_symbol" then ::Artifacts::NativeSymbol
        else raise ::Artifacts::Rejected, "invalid_artifact_dependencies"
        end
      end

      def available(project_ids:, dependencies:)
        dependencies.group_by { |entry| entry.fetch("kind") }.flat_map do |kind, entries|
          model(kind).where(project_id: project_ids, id: entries.map { |entry| entry.fetch("id") }).pluck(:project_id, :id)
            .map { |project, id| [ project, kind, id ] }
        end
      end
    end
  end
end
