# frozen_string_literal: true

module Github
  module Issues
    # Where a ticket change leaves for GitHub. The push is queued after the real commit and only for a
    # linked ticket; while a change that came FROM GitHub is applied nothing is queued, so it cannot
    # bounce back. The push itself also sends only what moved since the last sync. CYRA-1055
    module Outbound
      STATE_KEY = :github_issues_inbound

      module_function

      def suppress
        previous = ActiveSupport::IsolatedExecutionState[STATE_KEY]
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = true
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
      end

      def suppressed? = ActiveSupport::IsolatedExecutionState[STATE_KEY] == true

      def ticket_changed(ticket)
        return if suppressed?

        ticket_id = ticket.id
        ActiveRecord.after_all_transactions_commit do
          Github::Issues::PushJob.perform_later(ticket_id:) if Github::Issue.exists?(ticket_id:)
        end
      end

      def comment_added(comment)
        return if suppressed? || comment.github_comment_id.present?

        comment_id = comment.id
        ticket_id = comment.ticket_id
        ActiveRecord.after_all_transactions_commit do
          Github::Issues::PushCommentJob.perform_later(comment_id:) if Github::Issue.exists?(ticket_id:)
        end
      end

      # The comment row is gone by then: the job receives what it needs to find the twin.
      def comment_removed(comment)
        return if suppressed? || comment.github_comment_id.blank? || comment.from_github?

        ticket_id = comment.ticket_id
        github_comment_id = comment.github_comment_id
        ActiveRecord.after_all_transactions_commit do
          Github::Issues::DeleteCommentJob.perform_later(ticket_id:, github_comment_id:) if Github::Issue.exists?(ticket_id:)
        end
      end
    end
  end
end
