# frozen_string_literal: true

module Agents
  module LiveEvents
    # Stores the steps the machine running an attempt reports while the agent works (CYAU-282). Only that
    # machine, only while the attempt runs. A step already stored is skipped, so a batch can be resent. The
    # code survives only if the project turned the code view on; the answer tells the machine which.
    class Record < ApplicationService
      MAX_EVENTS = 200
      MAX_TEXT = 1000
      MAX_CODE_LINES = 400
      MAX_LINE_CHARS = 600
      HUNK_NUMBERS = { "oldStart" => "old_start", "oldLines" => "old_lines",
                       "newStart" => "new_start", "newLines" => "new_lines" }.freeze

      class Invalid < StandardError; end

      def initialize(host:, attempt:, events:)
        @host = host
        @attempt = attempt
        @events = events
      end

      def call
        return not_owner unless @attempt.host_id == @host.id
        return not_running unless @attempt.status_running?

        project = @attempt.workflow.ticket.project
        include_code = project.automator_live_code_enabled?
        rows = parse_batch(include_code)
        if rows.any?
          AttemptLiveEvent.insert_all(rows, unique_by: %i[attempt_id seq]) # rubocop:disable Rails/SkipsModelValidations
          Broadcast.moved(@attempt, project_id: project.id)
        end
        Result.ok({ accepted_through: @attempt.live_events.maximum(:seq) || 0, include_code: })
      rescue Invalid
        invalid
      end

      private

      def parse_batch(include_code)
        raise Invalid unless @events.is_a?(Array) && @events.size <= MAX_EVENTS

        now = Time.current
        @events.map do |item|
          raise Invalid unless item.is_a?(Hash)

          kind, payload = item["truncated"] == true ? [ "truncated", {} ] : parse_event(item["event"], include_code)
          { organization_id: @attempt.organization_id, attempt_id: @attempt.id, seq: positive(item["seq"]),
            kind:, payload:, recorded_at: time(item["at"]), created_at: now }
        end
      end

      def parse_event(event, include_code)
        raise Invalid unless event.is_a?(Hash)

        case event["kind"]
        when "file_change" then [ "file_change", file_change(event, include_code) ]
        when "file_read" then [ "file_read", { "path" => path(event["path"]) } ]
        when "search" then [ "search", { "pattern" => text(event["pattern"]) } ]
        when "command" then [ "command", { "command" => text(event["command"]) } ]
        else raise Invalid
        end
      end

      def file_change(event, include_code)
        raise Invalid unless [ true, false ].include?(event["created"])

        hunks = event["hunks"].nil? ? nil : parse_hunks(event["hunks"])
        # Without the code view only the text goes: where it changed stays for the conflict check (CYAU-299).
        hunks = hunks&.map { it.merge("lines" => []) } unless include_code
        { "path" => path(event["path"]), "created" => event["created"], "added" => count(event["added"]),
          "removed" => count(event["removed"]), "hunks" => hunks }
      end

      def parse_hunks(hunks)
        raise Invalid unless hunks.is_a?(Array) && hunks.all?(Hash)

        parsed = hunks.map do |hunk|
          numbers = HUNK_NUMBERS.to_h { |wire, stored| [ stored, count(hunk[wire]) ] }
          lines = hunk["lines"]
          raise Invalid unless lines.is_a?(Array) && lines.all? { it.is_a?(String) && it.length <= MAX_LINE_CHARS }

          numbers.merge("lines" => lines)
        end
        raise Invalid if parsed.sum { it["lines"].size } > MAX_CODE_LINES

        parsed
      end

      def path(value)
        raise Invalid if value.is_a?(String) && (value.start_with?("/") || value.split("/").include?(".."))

        text(value)
      end

      def text(value)
        raise Invalid unless value.is_a?(String) && value.length.between?(1, MAX_TEXT)

        value
      end

      def count(value)
        raise Invalid unless value.is_a?(Integer) && value >= 0

        value
      end

      def positive(value)
        raise Invalid unless value.is_a?(Integer) && value.positive?

        value
      end

      def time(value)
        raise Invalid unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        raise Invalid
      end

      def not_owner
        Result.err(AppError.new("The attempt is not run by this host", code: "R409-LIVE-001", status: :conflict))
      end

      def not_running
        Result.err(AppError.new("The attempt is over", code: "R409-LIVE-002", status: :conflict))
      end

      def invalid
        Result.err(AppError.new("Invalid live event batch", code: "R422-LIVE-001", status: :unprocessable_content))
      end
    end
  end
end
