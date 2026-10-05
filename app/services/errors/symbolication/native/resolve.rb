# frozen_string_literal: true

module Errors
  class Symbolication
    module Native
      class Resolve < ApplicationService
        MAX_DOWNLOAD = 100.megabytes
        MAX_ARTIFACTS = 10

        def initialize(event:)
          @event = event
          @dependencies = []
        end

        def call
          Timeout.timeout(30, ::Artifacts::Unavailable, "Native resolution deadline exceeded") { resolve }
        rescue ::Artifacts::Unavailable
          failure("processing_unavailable", retryable: true)
        rescue ::Artifacts::Rejected => error
          failure(error.message == "native_budget" ? "native_budget" : "processing_rejected")
        end

        private

        def resolve
          @report = Source.find(@event)
          return failure("crash_report_unavailable") unless @report
          @source = { "report_id" => @report.id, "manifest_sha256" => Source.digest(@report.manifest) }
          @frames = Stack.call(manifest: @report.manifest)
          wanted = @frames.filter_map { |frame| frame["identity"] }.uniq
          scope = wanted.reduce(@event.project.native_symbol_artifacts.none) { |relation, identity| relation.or(@event.project.native_symbol_artifacts.where(identity.compact)) }
          artifacts = scope.includes(:blob).limit(MAX_ARTIFACTS + 1).to_a
          raise ::Artifacts::Rejected, "native_budget" if artifacts.size > MAX_ARTIFACTS
          selected = select_artifacts(artifacts)
          groups = selected.group_by { |_frame, artifact| artifact.id }
          raise ::Artifacts::Rejected, "native_budget" if groups.size > MAX_ARTIFACTS || groups.values.sum { |rows| rows.first.last.blob.byte_size } > MAX_DOWNLOAD
          groups.each_value { |rows| resolve_artifact(rows) }
          count = @frames.count { |frame| frame["status"] == "resolved" }
          status = count.zero? ? "unresolved" : (count == @frames.size ? "resolved" : "partial")
          native = @source.merge("modules" => @report.manifest.fetch("modules", []), "threads" => @report.manifest.fetch("threads", []).each_with_index.map { |thread, index| { "thread_index" => index, "thread_id" => thread["thread_id"], "frame_count" => thread.fetch("frames", []).size } })
          result = { "version" => 1, "kind" => "native", "status" => status, "frames" => @frames, "dependencies" => @dependencies, "native" => native }
          result.to_json.bytesize > 1.megabyte ? failure("native_budget") : result
        end

        def select_artifacts(artifacts)
          @frames.filter_map do |frame|
            identity = frame.delete("identity")
            next if frame["status"] || !identity
            matches = artifacts.select { |artifact| identity.compact.all? { |key, value| artifact.public_send(key) == value } }
            unless matches.one?
              frame["status"] = matches.empty? ? "missing_artifact" : "ambiguous_artifact"
              next
            end
            [ frame, matches.sole ]
          end
        end

        def resolve_artifact(rows)
          artifact = rows.first.last
          expected = artifact.attributes.slice("format", "architecture", "debug_id", "code_id")
          bytes = ::Artifacts::NativeSymbols::Read.call(artifact: artifact)
          result = ::Artifacts::NativeSymbols::Processor.call(bytes: bytes, expected: expected, addresses: rows.map { |frame, _| "0x#{frame.fetch("module_offset").to_i(16).to_s(16)}" })
          @dependencies << { "kind" => "native_symbol", "id" => artifact.id }
          rows.each_with_index do |(frame, _), index|
            output = result.fetch("frames").fetch(index)
            frame.merge!("artifact_kind" => "native_symbol", "artifact_id" => artifact.id, "status" => output.fetch("status") == "resolved" ? "resolved" : "unmapped",
              "locations" => output.fetch("locations").map { |location| scrub(location) })
          end
        end

        def scrub(location)
          location.transform_keys(&:to_s).to_h do |key, value|
            clean = %w[file function symbol].include?(key) && value.is_a?(String) ? Errors::Ingest::Scrub.call(payload: value) : value
            [ key, clean ]
          end
        end

        def failure(reason, retryable: false)
          { "version" => 1, "kind" => "native", "status" => "unresolved", "reason" => reason, "retryable" => retryable, "frames" => [], "dependencies" => [], "native" => @source || {} }
        end
      end
    end
  end
end
