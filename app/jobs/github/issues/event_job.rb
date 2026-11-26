# frozen_string_literal: true

module Github
  module Issues
    # One GitHub delivery about an issue, its comments or its board card. One at a time per issue: two
    # deliveries racing on a new issue would make two tickets, and a push racing an arrival would
    # compare against a state that is about to change. CYRA-1055
    class EventJob < ApplicationJob
      queue_as :ingest

      limits_concurrency to: 1, key: ->(key:, **) { "github:issue:#{key}" }, group: "github:issue"

      def perform(event:, payload:, key:, delivery_id: nil)
        if delivery_id
          Github::WebhookDelivery.find(delivery_id).process do |received_event, received_payload|
            result = dispatch(received_event, received_payload)
            raise "GitHub webhook handler failed" if result.respond_to?(:ok?) && !result.ok?
          end
        else
          dispatch(event, payload)
        end
      end

      private

      def dispatch(event, payload)
        case event
        when "issues" then Github::Webhooks::Issues.call(payload:)
        when "issue_comment" then Github::Webhooks::IssueComment.call(payload:)
        when "projects_v2_item" then Github::Webhooks::ProjectsV2Item.call(payload:)
        end
      end
    end
  end
end
