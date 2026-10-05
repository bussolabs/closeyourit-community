# frozen_string_literal: true

module Member
  module Monitoring
    class NativeSymbolicationPresenter
      MAX_FRAMES = 500
      attr_reader :reason

      def initialize(result:, report:)
        @result, @report = result, report
        @manifest = report&.fetch("manifest", nil).is_a?(Hash) ? report["manifest"] : {}
        @reason = result["reason"]
        expected = result["native"]
        @matches = report && expected.is_a?(Hash) && expected["report_id"] == report["id"] && expected["manifest_sha256"] == report["manifest_sha256"]
        @reason = "crash_report_unavailable" if !@matches && rows(result["frames"]).any?
        @reason = "native_source_budget" if raw_threads.sum { |thread| rows(thread["frames"]).size } > MAX_FRAMES
      end

      def threads
        return [] if @reason == "native_source_budget"
        @threads ||= indexed_rows(@manifest["threads"]).map do |thread, index|
          { index: index, id: thread["thread_id"], frames: indexed_rows(thread["frames"]).map { |frame, position| frame_row(frame, index, position) } }
        end
      end

      def selected_thread
        crash = @manifest["crash_info"]
        index = crash["crashing_thread"] if crash.is_a?(Hash)
        index.is_a?(Integer) && threads.any? { |thread| thread[:index] == index } ? index : threads.first&.fetch(:index)
      end

      def modules = rows(@manifest["modules"])
      def available? = @report.present?
      def status = %w[crash_report_unavailable native_source_budget].include?(@reason) ? "unresolved" : @result.fetch("status", "pending")

      private

      def raw_threads = rows(@manifest["threads"])
      def rows(value) = value.is_a?(Array) ? value.select { |item| item.is_a?(Hash) } : []
      def indexed_rows(value) = value.is_a?(Array) ? value.each_with_index.filter_map { |item, index| [ item, index ] if item.is_a?(Hash) } : []

      def frame_row(frame, thread, index)
        derived = @matches ? derived_frames[[ thread, index ]] : nil
        module_index = derived&.fetch("module_index", nil)
        { index: index, received: frame, status: derived&.fetch("status", nil) || @reason || "pending",
          locations: derived && derived["status"] == "resolved" ? rows(derived["locations"]) : [],
          module: module_at(module_index) }
      end

      def module_at(index)
        values = @manifest["modules"]
        value = values[index] if values.is_a?(Array) && index.is_a?(Integer) && index >= 0
        value if value.is_a?(Hash)
      end

      def derived_frames
        @derived_frames ||= rows(@result["frames"]).to_h { |frame| [ [ frame["thread_index"], frame["frame_index"] ], frame ] }
      end
    end
  end
end
