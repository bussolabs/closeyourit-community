# frozen_string_literal: true

module Github
  # Effects and receipt completion commit together under the receipt's row lock.
  class WebhookJob < ApplicationJob
    queue_as :ingest
    self.enqueue_after_transaction_commit = false

    def perform(delivery_id: nil, event: nil, payload: nil)
      if delivery_id
        Github::WebhookDelivery.find(delivery_id).process do |received_event, received_payload|
          result = dispatch(received_event, received_payload)
          raise "GitHub webhook handler failed" if result.respond_to?(:ok?) && !result.ok?
        end
      else
        # Jobs queued before receipts existed have no signed raw body to attest.
        dispatch(event, payload)
      end
    end

    private

    def dispatch(event, payload)
      case event
      when "push"         then Github::Webhooks::Push.call(payload:)
      when "create"       then Github::Webhooks::Create.call(payload:)
      when "release"      then Github::Webhooks::Release.call(payload:)
      when "installation" then Github::Webhooks::Installation.call(payload:)
      when "pull_request" then Github::Webhooks::PullRequest.call(payload:)
      when "workflow_job" then Github::Webhooks::WorkflowJob.call(payload:)
      end
    end
  end
end
