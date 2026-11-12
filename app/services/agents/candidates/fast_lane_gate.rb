# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1300 — a delivery whose plan took the fast lane keeps it only if its real changes are as small as
    # promised: past the limits, or outside the files the plan named, a person decides. It does not follow the
    # project's delivery check: a plan nobody read is always checked on what it really changed.
    class FastLaneGate < DeliveryGate
      ACTION_STOPPED = "delivery_fast_lane_stopped"
      # Added plus deleted lines, on the files that are not tests.
      MAX_LINES = 60

      def stops?
        return false unless Agents::Plans::FastLane.taken?(@workflow)

        verdict = read_verdict
        record_event!(ACTION_STOPPED, verdict) if verdict[:reasons].any?
        verdict[:reasons].any?
      end

      private

      def mode = ScopeCheck::MODE_ON
      def client = @client ||= Github::Client.new

      # An unreadable or cut file list is not a small one.
      def read_verdict
        read = client.pull_request_files(@candidate.repository.github_installation_id,
                                         @candidate.repository_full_name, @candidate.number)
        files = read[:files].reject { |file| ScopeCheck::TEST_PATHS.any? { |pattern| file[:path].to_s.match?(pattern) } }
        lines = files.sum { |file| file[:additions].to_i + file[:deletions].to_i }
        outside = files.map { |file| file[:path].to_s } - declared_paths
        reasons = []
        reasons << "files_unknown" if read[:truncated]
        reasons << "too_many_files" if files.size > Agents::Plans::FastLane::MAX_FILES
        reasons << "too_many_lines" if lines > MAX_LINES
        reasons << "outside_plan" if outside.any?
        { reasons:, files: files.size, lines:, outside_plan: outside.first(ScopeCheck::LISTED_MAX) }
      rescue Github::Client::Error
        { reasons: [ "files_unknown" ], files: 0, lines: 0, outside_plan: [] }
      end
    end
  end
end
