# frozen_string_literal: true

# Commento di un'idea per la CLI. Specchio di CommentSerializer (ticket) con la FK dell'idea.
class IdeaCommentSerializer < ApplicationSerializer
  attributes :id, :idea_id, :body, :created_at, :updated_at

  attribute(:author) { |comment| comment.author&.name }
end
