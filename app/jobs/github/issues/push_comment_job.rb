# frozen_string_literal: true

module Github
  module Issues
    # Sends a CloseYourIt comment to the linked issue (Github::Issues::PushComment), in line with the
    # other work on the same issue. CYRA-1055
    class PushCommentJob < ApplicationJob
      queue_as :default

      limits_concurrency to: 1, key: ->(comment_id:) {
        ticket_id = Ticketing::Comment.where(id: comment_id).pick(:ticket_id)
        "github:issue:#{Github::Issue.where(ticket_id:).pick(:node_id) || ticket_id}"
      }, group: "github:issue"

      def perform(comment_id:)
        comment = Ticketing::Comment.find_by(id: comment_id)
        return if comment.nil?

        Github::Issues::PushComment.call(comment:)
      rescue Github::Client::Error => e
        raise if e.transient?

        Rails.logger.warn("[github.issues.comment] #{e.code} comment=#{comment_id}: #{e.message}")
      end
    end
  end
end
