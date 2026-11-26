# frozen_string_literal: true

module Alerting
  # A button click from Slack, queued by Slack::InteractionsController. The same click delivered twice
  # runs once; two different clicks are serialized by Alerting::SlackAction. CYRA-1156
  class SlackActionJob < ApplicationJob
    queue_as :alerts

    def perform(click)
      key = "alerting:slack-click:#{click['team_id']}:#{click['user_id']}:#{click['action_ts']}"
      return unless Rails.cache.write(key, true, unless_exist: true, expires_in: 1.hour)

      SlackAction.call(team_id: click["team_id"], user_id: click["user_id"], channel: click["channel"],
                       ts: click["ts"], action: click["action"])
    end
  end
end
