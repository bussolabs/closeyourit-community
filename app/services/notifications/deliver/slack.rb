# frozen_string_literal: true

module Notifications
  class Deliver
    # Delivery on a Slack app channel: the alert with its three buttons, posted by the Puckies' app. The
    # message is remembered so clicks and the recovery can change it later. Same rules as the webhook:
    # the test lab is intercepted, a failure is logged and never stops the pipeline. CYRA-1156
    # Failures are classified for the queued delivery (CYRA-1227): Slack unreachable or «ratelimited» is
    # R502-ALERT-003 and is retried; any other refusal (channel gone, app removed, token revoked) and an
    # app without credentials are R422-ALERT-005, never retried.
    class Slack < ApplicationService
      def initialize(channel:, rule:, event_type:, subject:, content:, delivery_id: nil)
        @channel = channel
        @rule = rule
        @event_type = event_type
        @subject = subject
        @content = content
        @delivery_id = delivery_id
      end

      def call
        if DevelopmentLab.organization?(@channel.organization)
          Rails.logger.info("Development lab Slack alert intercepted")
          return Result.ok(:lab_intercepted)
        end

        message = build_message
        card = Alerting::SlackCard.new(message)
        answer = ::Coworkers::Slack.post_blocks(channel: message.slack_channel, text: card.text, blocks: card.blocks,
                                                delivery_id: @delivery_id)
        return unanswered if answer.nil?
        return refused(answer) unless answer["ok"]

        message.update!(slack_channel: answer["channel"].presence || message.slack_channel, slack_ts: answer["ts"])
        Result.ok(message)
      rescue StandardError => e
        Rails.logger.warn("Alerting Slack #{@channel.id} fallito: #{e.class} #{e.message}")
        TransientFailure === e ? transient("Slack irraggiungibile") : definitive("Invio Slack fallito")
      end

      private

      def build_message
        Alerting::SlackMessage.new(
          organization: @channel.organization, channel: @channel, rule: @rule, project_id: @content.project&.id,
          event_type: @event_type, subject_type: @subject.class.name, subject_id: @subject.id,
          slack_channel: @channel.slack_channel, title: @content.title.to_s.first(250), body: @content.body,
          url: @content.url
        )
      end

      # Coworkers::Slack answers nil both when the app has no credentials and when the call itself
      # failed (timeout, connection, non-JSON answer): only the second can heal by itself.
      def unanswered
        Rails.logger.warn("Alerting Slack #{@channel.id} → no answer")
        return definitive("App Slack non configurata") unless ::Coworkers::Slack.configured?

        transient("Slack irraggiungibile")
      end

      def refused(answer)
        error = answer["error"].to_s
        Rails.logger.warn("Alerting Slack #{@channel.id} → #{error.presence || 'refused'}")
        return transient("Slack chiede di riprovare più tardi") if error == "ratelimited"

        definitive("Slack ha rifiutato il messaggio")
      end

      def transient(message)
        Result.err(AppError.new(message, code: "R502-ALERT-003", status: :bad_gateway))
      end

      def definitive(message)
        Result.err(AppError.new(message, code: "R422-ALERT-005"))
      end
    end
  end
end
