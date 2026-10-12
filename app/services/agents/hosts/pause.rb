# frozen_string_literal: true

module Agents
  module Hosts
    # Pauses a machine: it finishes the work it holds and takes no new one (the queue answers "no work").
    # A duration makes the pause end by itself; pausing again replaces the previous pause.
    class Pause < ApplicationService
      def initialize(host:, actor:, duration: nil, reason: nil, now: Time.current)
        @host = host
        @actor = actor
        @duration = duration.presence || Agents::Constants::PAUSE_WITHOUT_END
        @reason = reason
        @now = now
      end

      def call
        return invalid_duration unless Agents::Constants::PAUSE_DURATIONS.key?(@duration)

        span = Agents::Constants::PAUSE_DURATIONS.fetch(@duration)
        @host.update!(paused_at: @now, paused_by: @actor, paused_until: span && (@now + span), pause_reason: @reason)
        Result.ok(@host)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-AGENT-011", details: e.record.errors.to_hash))
      end

      private

      def invalid_duration
        Result.err(AppError.new("Unknown pause duration", code: "R422-AGENT-011", details: { duration: [ @duration ] }))
      end
    end
  end
end
