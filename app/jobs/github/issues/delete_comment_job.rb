# frozen_string_literal: true

module Github
  module Issues
    # A comment deleted on CloseYourIt takes its twin on the linked issue with it. CYRA-1055
    class DeleteCommentJob < ApplicationJob
      queue_as :default

      limits_concurrency to: 1, key: ->(ticket_id:, **) { "github:issue:#{Github::Issue.where(ticket_id:).pick(:node_id) || ticket_id}" },
                         group: "github:issue"

      def perform(ticket_id:, github_comment_id:)
        link = Github::Issue.find_by(ticket_id:)
        return if link.nil? || !link.repository.issue_sync_live?

        repository = link.repository
        Github::Client.new.delete_issue_comment(repository.github_installation_id, repository.full_name, github_comment_id)
      rescue Github::Client::Error => e
        raise if e.transient?

        Rails.logger.warn("[github.issues.comment_delete] #{e.code} ticket=#{ticket_id}: #{e.message}")
      end
    end
  end
end
