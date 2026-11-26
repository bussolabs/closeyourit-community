# frozen_string_literal: true

module Github
  # Effects and receipt completion commit together under the receipt's row lock.
  class WebhookJob < ApplicationJob
    queue_as :ingest
    self.enqueue_after_transaction_commit = false

    # Issues, their comments and board cards go one at a time per issue (CYRA-1055).
    ISSUE_EVENTS = %w[issues issue_comment projects_v2_item].freeze

    def perform(delivery_id: nil, event: nil, payload: nil)
      if delivery_id
        receipt = Github::WebhookDelivery.find(delivery_id)
        return if receipt.completed_at
        return enqueue_issue_receipt(receipt) if ISSUE_EVENTS.include?(receipt.event)

        receipt.process do |received_event, received_payload|
          result = dispatch(received_event, received_payload)
          raise "GitHub webhook handler failed" if result.respond_to?(:ok?) && !result.ok?
        end
      else
        # Jobs queued before receipts existed have no signed raw body to attest.
        dispatch(event, payload)
      end
    end

    private

    # The serialized issue job completes the receipt only after its effects commit (CYRA-1212, CYRA-1055).
    def enqueue_issue_receipt(receipt)
      payload = JSON.parse(receipt.body)
      Github::Issues::EventJob.perform_later(event: receipt.event, payload: {}, key: issue_key(receipt.event, payload), delivery_id: receipt.id)
    end

    def dispatch(event, payload)
      return Github::Issues::EventJob.perform_later(event:, payload:, key: issue_key(event, payload)) if ISSUE_EVENTS.include?(event)

      case event
      when "push"         then Github::Webhooks::Push.call(payload:)
      when "create"       then Github::Webhooks::Create.call(payload:)
      when "release"      then Github::Webhooks::Release.call(payload:)
      when "installation" then Github::Webhooks::Installation.call(payload:)
      when "pull_request" then Github::Webhooks::PullRequest.call(payload:)
      when "workflow_job" then Github::Webhooks::WorkflowJob.call(payload:)
      end
    end

    # The issue's GitHub node id: the same key the push of its ticket uses.
    def issue_key(event, payload)
      source = payload.is_a?(Hash) ? payload : {}
      item = source["projects_v2_item"]
      issue = source["issue"]
      key = issue.is_a?(Hash) ? issue["node_id"] : nil
      key = item.is_a?(Hash) ? item["content_node_id"].presence || item["node_id"] : nil if event == "projects_v2_item"
      key.presence&.to_s || "unknown"
    end
  end
end
