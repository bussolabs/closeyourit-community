# frozen_string_literal: true

module Errors
  class Symbolication
    module Java
      class Resolve < ApplicationService
        def initialize(event:)
          @event = event
          @project = event.project
        end

        def call
          return unresolved("missing_build_identity") if @event.release.blank?
          identity = build_identity
          return unresolved("missing_build_identity") unless identity
          artifact = @project.proguard_map_artifacts.includes(:blob).find_by(identity_sha256: Digest::SHA256.hexdigest(identity.to_json))
          unless artifact
            known = @project.proguard_map_artifacts.exists?(debug_id: identity[:debug_id])
            return unresolved(known ? "identity_mismatch" : "missing_artifact")
          end
          values = @event.payload.dig("exception", "values")
          input = Stack.call(values: values)
          mapping = ::Artifacts::ProguardMaps::Read.call(artifact: artifact)
          output = ::Artifacts::ProguardMaps::Processor.call(mapping: mapping, stacktrace: input.map { |entry| entry["line"] })
          groups = output.each_with_index.map { |group, index| project_group(group, input.fetch(index), artifact) }
          frames = groups.select { |group| group["kind"] == "frame" }
          mapped = groups.count { |group| %w[mapped removed].include?(group["status"]) }
          status = mapped.zero? ? "unresolved" : (mapped == groups.size ? "resolved" : "partial")
          result = { "version" => 1, "kind" => "proguard", "status" => status,
            "dependencies" => [ { "kind" => "proguard_map", "id" => artifact.id } ], "groups" => groups, "frames" => frames }
          result.to_json.bytesize <= 1.megabyte ? result : unresolved("symbolication_budget")
        rescue ::Artifacts::Rejected => error
          unresolved(rejection_reason(error.message))
        rescue ::Artifacts::Unavailable
          unresolved("processing_unavailable").merge("retryable" => true)
        rescue TypeError, NoMethodError
          unresolved("unsupported_stack")
        end

        private

        def rejection_reason(code)
          case code
          when "unsupported_stack", "invalid_stack" then "unsupported_stack"
          when "request_too_large" then "symbolication_budget"
          when "retrace_rejected", "invalid_mapping" then "processing_rejected"
          else "identity_mismatch"
          end
        end

        def build_identity
          metadata = @event.payload["debug_meta"]
          images = metadata.is_a?(Hash) ? metadata["images"] : nil
          return nil unless images.is_a?(Array)
          candidates = images.select { |image| image.is_a?(Hash) && image["type"] == "proguard" }
          return nil if candidates.empty?
          ids = candidates.map { |image| ::Artifacts::SourceMaps::Identity.debug_id(image["uuid"]) }.uniq
          raise ::Artifacts::Rejected, "identity_mismatch" unless ids.size == 1
          ::Artifacts::ProguardMaps::Identity.call(metadata: { "release" => @event.release, "dist" => @event.payload["dist"], "debug_id" => ids.first })
        end

        def project_group(group, source, artifact)
          alternatives = group.fetch("alternatives")
          status = if group.fetch("ambiguous") || alternatives.size > 1
            "ambiguous"
          elsif alternatives.empty? || alternatives.first.fetch("lines").empty?
            "removed"
          elsif alternatives.first.fetch("lines") == [ source.fetch("line") ]
            "unmapped"
          else
            "mapped"
          end
          source.except("line").merge("index" => group.fetch("index"), "status" => status,
            "artifact_kind" => "proguard_map", "artifact_id" => artifact.id,
            "alternatives" => Errors::Ingest::Scrub.call(payload: alternatives))
        end

        def unresolved(reason)
          { "version" => 1, "kind" => "proguard", "status" => "unresolved", "reason" => reason, "dependencies" => [], "groups" => [], "frames" => [] }
        end
      end
    end
  end
end
