# frozen_string_literal: true

module Alerting
  # Frozen content and identity survive retries; destination changes cancel the event.
  # Secrets are read fresh. Hourly cleanup removes jobs finished more than an hour ago;
  # this is not a one-hour deletion guarantee. See docs/alert-channel-delivery.md. CYRA-1227
  class DeliverChannelJob < ApplicationJob
    queue_as :alert_webhooks
    self.log_arguments = false

    ProjectSnapshot = Data.define(:id, :key, :name)

    retry_on TransientFailure, wait: :polynomially_longer, attempts: MAX_ATTEMPTS do |job, _error|
      job.class.release(job.arguments.first)
    end

    def self.release(args)
      ChannelReservation.release(channel_id: args[:channel_id], key: args[:throttle_key], token: args[:reservation_token])
    end

    # Retry enqueue failures must release the same reservation as initial enqueue failures.
    def retry_job(options = {})
      job = super
      self.class.release(arguments.first) unless job
      job
    rescue StandardError
      self.class.release(arguments.first)
      raise
    end

    def perform(channel_id:, rule_id:, organization_id:, link_id:, destination_digest:, event_type:,
                subject_type:, subject_id:, content:, occurred_at:, throttle_key:, reservation_token:,
                window_expires_at:, metric: nil, delivery_id: nil)
      # Checked before every attempt (AC-8): past its window the alert belongs to the next event.
      if Time.current >= window_expires_at || ChannelReservation.superseded?(key: throttle_key, token: reservation_token)
        self.class.release(arguments.first)
        return
      end

      channel = Alerting::Channel.enabled.find_by(id: channel_id, organization_id: organization_id)
      rule = Alerting::Rule.notifying.find_by(id: rule_id, organization_id: organization_id,
                                              event_type: rule_event_type(event_type, metric))
      subject = subject_type.safe_constantize&.find_by(id: subject_id)
      unless authorized?(channel, rule, link_id, destination_digest) &&
          ChannelSubject.authorized?(subject, rule: rule, project_id: content.dig(:project, :id))
        self.class.release(arguments.first)
        return
      end

      result = if channel.kind_slack_app?
        Alerting::Deliver.slack(channel:, rule:, event_type:, subject:, content: snapshot(content), delivery_id:)
      else
        Alerting::Deliver.webhook(channel:, event_type:, subject:, content: snapshot(content), occurred_at:, delivery_id:)
      end
      return if result.ok?
      raise result.error if TransientFailure === result.error

      self.class.release(arguments.first)
    rescue StandardError => error
      self.class.release(arguments.first) unless TransientFailure === error
      raise
    end

    private

    # The return under threshold travels on a rule of its own measurement (CYRA-1256): only that pair
    # is accepted, every other event still needs a rule of its very type.
    def rule_event_type(event_type, metric)
      return event_type unless event_type == "server_threshold_recovered"

      metric if Alerting::Rule::THRESHOLD_EVENT_TYPES.include?(metric)
    end

    def authorized?(channel, rule, link_id, destination_digest)
      channel && rule && Digest::SHA256.hexdigest(channel.target) == destination_digest &&
        Alerting::RuleChannel.exists?(id: link_id, rule_id: rule.id, channel_id: channel.id)
    end

    def snapshot(content)
      project = ProjectSnapshot.new(**content[:project]) if content[:project]
      Alerting::Content.new(title: content[:title], body: content[:body], url: content[:url], project:, details: nil)
    end
  end
end
