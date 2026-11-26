# frozen_string_literal: true

module Alerting
  # Writes the state of an alert back into its Slack message. Each refresh carries the version it was
  # queued for: one older than the latest change, or than the last one written, is dropped. CYRA-1156
  class SlackRefreshJob < ApplicationJob
    queue_as :alerts

    def perform(message_id, version)
      message = SlackMessage.find_by(id: message_id)
      return if message.nil?

      # The lock keeps two refreshes from reaching Slack out of order.
      message.with_lock do
        next if version < message.version || version <= message.rendered_version

        card = SlackCard.new(message)
        answer = Coworkers::Slack.update(channel: message.slack_channel, ts: message.slack_ts, text: card.text, blocks: card.blocks)
        if answer && answer["ok"]
          message.update_columns(rendered_version: version)
        else
          Rails.logger.warn("[alerting.slack] refresh failed message=#{message.id} error=#{answer&.dig('error')}")
        end
      end
    end
  end
end
