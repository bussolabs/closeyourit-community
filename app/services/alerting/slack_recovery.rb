# frozen_string_literal: true

module Alerting
  # When an alert recovers, its open Slack messages say so and lose their buttons. The pairs are the
  # ones of Alerting::Recoveries: same subject, the down alert of this up. CYRA-1156
  class SlackRecovery < ApplicationService
    def initialize(event_type:, subject:, at: Time.current)
      @event_type = event_type.to_s
      @subject = subject
      @at = at
    end

    def call
      downs = Recoveries::PAIRS.select { |_down, up| up == @event_type }.keys
      return 0 if downs.empty?

      messages = SlackMessage.status_open.for_subject(@subject).where(event_type: downs).to_a
      messages.count { |message| message.change!(status: :recovered, recovered_at: @at) }
    end
  end
end
