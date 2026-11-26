# frozen_string_literal: true

module Notifications
  class Deliver
    # Delivery on a Slack app channel: the alert with its three buttons, posted by the Puckies' app. The
    # message is remembered so clicks and the recovery can change it later. Same rules as the webhook:
    # the test lab is intercepted, a failure is logged and never stops the pipeline. CYRA-1156
    class Slack < ApplicationService
      def initialize(channel:, rule:, event_type:, subject:, content:)
        @channel = channel
        @rule = rule
        @event_type = event_type
        @subject = subject
        @content = content
      end

      def call
        if DevelopmentLab.organization?(@channel.organization)
          Rails.logger.info("Development lab Slack alert intercepted")
          return Result.ok(:lab_intercepted)
        end

        message = build_message
        card = Alerting::SlackCard.new(message)
        answer = ::Coworkers::Slack.post_blocks(channel: message.slack_channel, text: card.text, blocks: card.blocks)
        return failed(answer) unless answer && answer["ok"]

        message.update!(slack_channel: answer["channel"].presence || message.slack_channel, slack_ts: answer["ts"])
        Result.ok(message)
      rescue StandardError => e
        Rails.logger.warn("Alerting Slack #{@channel.id} fallito: #{e.class} #{e.message}")
        Result.err(AppError.new("Slack irraggiungibile", code: "R502-ALERT-003", status: :bad_gateway))
      end

      private

      def build_message
        Alerting::SlackMessage.new(
          organization: @channel.organization, channel: @channel, rule: @rule, project: @content.project,
          event_type: @event_type, subject_type: @subject.class.name, subject_id: @subject.id,
          slack_channel: @channel.slack_channel, title: @content.title.to_s.first(250), body: @content.body,
          url: @content.url
        )
      end

      def failed(answer)
        Rails.logger.warn("Alerting Slack #{@channel.id} → #{answer&.dig('error') || 'no answer'}")
        Result.err(AppError.new("Slack ha rifiutato il messaggio", code: "R502-ALERT-003", status: :bad_gateway))
      end
    end
  end
end
