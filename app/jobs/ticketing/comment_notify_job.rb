# frozen_string_literal: true

module Ticketing
  # Fan-out delle notifiche per un nuovo commento (commented/mentioned). Enqueued da AddComment dopo
  # il salvataggio del commento. Idempotente (dedup_key): un retry non duplica. Commento sparito → no-op.
  class CommentNotifyJob < ApplicationJob
    queue_as :notifications

    def perform(comment_id:, mentioned_ids: [])
      comment = Ticketing::Comment.find_by(id: comment_id)
      return if comment.nil?

      Ticketing::Notifications::DispatchComment.call(comment: comment, mentioned_ids: mentioned_ids)
    end
  end
end
