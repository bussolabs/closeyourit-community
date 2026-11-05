# frozen_string_literal: true

module Agents
  # CYRA-1178 — what the row and the machine page say after the Automator watchdog reported a hang.
  module HangHelper
    # How long the row still says a machine was blocked and came back.
    HANG_NOTICE_WINDOW = 24.hours

    # "Blocked N minutes, resumed" after the watchdog reported the end of a hang. Nil otherwise.
    def agent_host_hang_summary(host)
      return unless host.hang.is_a?(Hash) && %w[resumed restarted].include?(host.hang["state"])

      reported_at = host.hang_reported_at
      return if reported_at.nil? || reported_at <= HANG_NOTICE_WINDOW.ago

      t("member.agents.hang.resumed", count: host.hang_minutes)
    end
  end
end
