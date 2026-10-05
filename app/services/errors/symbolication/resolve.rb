# frozen_string_literal: true

module Errors
  class Symbolication
    class Resolve < ApplicationService
      MAX_FRAMES = 500
      MAX_MAP_BYTES = 10.megabytes

      def initialize(event:)
        @event = event
        @project = event.project
        @cache = {}
        @bytes = 0
        @frames = []
      end

      def call
        return Native::Resolve.call(event: @event) if native_event?
        return Java::Resolve.call(event: @event) if @event.payload["platform"] == "java"
        primary = frames_in(@event.stacktrace)
        exceptions = @event.payload.dig("exception", "values")
        exceptions = exceptions.is_a?(Array) ? exceptions : []
        all = primary + exceptions.flat_map { |exception| exception.is_a?(Hash) ? frames_in(exception["stacktrace"]) : [] }
        return budget_result if all.size > MAX_FRAMES
        keys = all.filter_map { |frame| identity_for(frame).last }
        @artifacts = @project.source_map_artifacts.includes(:blob).where(identity_sha256: keys).index_by(&:identity_sha256)
        paths = all.filter_map { |frame| path_for(frame) }.uniq
        @known_paths = @project.source_map_artifacts.where(generated_file: paths).distinct.pluck(:generated_file)
        stacktrace = @event.stacktrace.deep_dup
        stacktrace["frames"] = resolve_frames(primary, exception_index: nil)
        resolved_exceptions = exceptions.each_with_index.map do |exception, index|
          next {} unless exception.is_a?(Hash)
          { "stacktrace" => { "frames" => resolve_frames(frames_in(exception["stacktrace"]), exception_index: index) } }
        end
        mapped = @frames.count { |frame| frame["status"] == "mapped" }
        status = mapped.zero? ? "unresolved" : (mapped == @frames.size ? "resolved" : "partial")
        result = { "version" => 1, "status" => status, "stacktrace" => stacktrace, "exceptions" => resolved_exceptions, "frames" => @frames }
        result.to_json.bytesize <= 1.megabyte ? result : budget_result
      end

      private

      def native_event?
        @event.payload["platform"] == "native" || @project.crash_reports.where(event_id: @event.event_id).where.not(manifest: {}).exists?
      end

      def frames_in(stack)
        stack.is_a?(Hash) && stack["frames"].is_a?(Array) ? stack["frames"] : []
      end

      def path_for(frame)
        return nil unless frame.is_a?(Hash)
        ::Artifacts::SourceMaps::Identity.generated_file(frame["abs_path"].presence || frame["filename"])
      rescue ::Artifacts::Rejected
        nil
      end

      def identity_for(frame)
        return [ "missing_position", nil ] unless frame.is_a?(Hash)
        path = path_for(frame)
        return [ "unsupported", nil ] unless path
        return [ "missing_build_identity", nil ] unless @event.release.present?
        debug_ids = []
        debug_ids << frame["debug_id"] if frame["debug_id"]
        metadata = @event.payload["debug_meta"]
        images = metadata.is_a?(Hash) ? metadata["images"] : nil
        if images.is_a?(Array)
          images.each do |image|
            next unless image.is_a?(Hash) && image["type"] == "sourcemap"
            next unless path_for({ "abs_path" => image["code_file"] }) == path
            debug_ids << image["debug_id"] if image["debug_id"]
          end
        end
        ids = debug_ids.map { |id| ::Artifacts::SourceMaps::Identity.debug_id(id) }.uniq
        return [ "identity_mismatch", nil ] if ids.size > 1
        identity = ::Artifacts::SourceMaps::Identity.call(metadata: { "release" => @event.release, "dist" => @event.payload["dist"], "generated_file" => path, "debug_id" => ids.first }, map: {})
        [ nil, Digest::SHA256.hexdigest(identity.to_json) ]
      rescue ::Artifacts::Rejected
        [ "identity_mismatch", nil ]
      end

      def resolve_frames(frames, exception_index:)
        frames.each_with_index.map do |frame, index|
          entry = { "index" => index, "exception_index" => exception_index }
          status, key = identity_for(frame)
          line = frame.is_a?(Hash) ? frame["lineno"] : nil
          column = frame.is_a?(Hash) ? frame["colno"] : nil
          status ||= "missing_position" unless [ line, column ].all? { |value| value.is_a?(Integer) && (1..::Artifacts::MAX_POSITION).cover?(value) }
          artifact = @artifacts[key]
          status ||= @known_paths.include?(path_for(frame)) ? "identity_mismatch" : "missing_artifact" unless artifact
          if status
            @frames << entry.merge("status" => status)
            next frame
          end
          map = load_map(artifact)
          unless map
            @frames << entry.merge("status" => "artifact_budget")
            next frame
          end
          match = ::Artifacts::SourceMaps::Lookup.call(map: map, line: line - 1, column: column - 1)
          unless match
            @frames << entry.merge("status" => "unmapped", "artifact_id" => artifact.id)
            next frame
          end
          @frames << entry.merge("status" => "mapped", "artifact_id" => artifact.id, **match)
          frame.merge(match.fetch("original")).merge("abs_path" => match.fetch("original").fetch("filename"))
        end
      end

      def load_map(artifact)
        return @cache[artifact.id] if @cache.key?(artifact.id)
        return nil if @bytes + artifact.blob.byte_size > MAX_MAP_BYTES
        @bytes += artifact.blob.byte_size
        @cache[artifact.id] = ::Artifacts::SourceMaps::Read.call(artifact: artifact)
      end

      def budget_result
        { "version" => 1, "status" => "unresolved", "reason" => "symbolication_budget", "frames" => [] }
      end
    end
  end
end
