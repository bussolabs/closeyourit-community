# frozen_string_literal: true

module Agents
  module LiveEvents
    # What the live page of an attempt shows, rebuilt from its stored steps (CYRA-1138): the files the agent
    # touched with their totals, each change in order, and the newest steps first. Reads only the latest
    # LIMIT steps, so a runaway session cannot make the page slow.
    class Session
      LIMIT = 2000
      TIMELINE_SIZE = 30

      Hunk = Data.define(:old_start, :old_lines, :new_start, :new_lines, :lines)
      Change = Data.define(:seq, :at, :added, :removed, :hunks) do
        # Hunks may carry only their line numbers when the project keeps the code on the machine (CYAU-299).
        def code? = Array(hunks).any? { it.lines.any? }
      end
      Step = Data.define(:seq, :at, :kind, :text, :added, :removed)

      FileEntry = Data.define(:path, :created, :changes) do
        def added = changes.sum(&:added)
        def removed = changes.sum(&:removed)
        def changed? = changes.any?
      end

      attr_reader :files, :timeline, :followed_path

      # events: the attempt's steps already loaded in seq order (the project view reads every agent at once).
      def initialize(attempt:, events: nil)
        events = events ? events.last(self.class::LIMIT) : attempt.live_events.order(seq: :desc).limit(self.class::LIMIT).to_a.reverse
        @truncated = events.any? { it.kind == "truncated" }
        @files = build_files(events)
        @followed_path = events.reverse.find { it.kind == "file_change" }&.payload&.dig("path")
        @timeline = events.reject { it.kind == "truncated" }.last(TIMELINE_SIZE).reverse.map { step(it) }
      end

      def file(path) = @files.find { it.path == path }

      def code? = @files.any? { |entry| entry.changes.any?(&:code?) }

      def truncated? = @truncated

      private

      def build_files(events)
        by_path = {}
        events.each do |event|
          path = event.payload["path"]
          next unless path && %w[file_change file_read].include?(event.kind)

          entry = by_path[path] ||= { created: false, changes: [] }
          next unless event.kind == "file_change"

          entry[:created] ||= event.payload["created"] == true
          entry[:changes] << change(event)
        end
        by_path.sort.map { |path, entry| FileEntry.new(path:, **entry) }
      end

      def change(event)
        hunks = event.payload["hunks"]&.map { Hunk.new(**it.symbolize_keys.slice(*Hunk.members)) }
        Change.new(seq: event.seq, at: event.recorded_at, added: event.payload["added"].to_i,
                   removed: event.payload["removed"].to_i, hunks:)
      end

      def step(event)
        payload = event.payload
        Step.new(seq: event.seq, at: event.recorded_at, kind: event.kind,
                 text: payload["path"] || payload["pattern"] || payload["command"],
                 added: payload["added"], removed: payload["removed"])
      end
    end
  end
end
