# frozen_string_literal: true

module Helpdesk
  # Requests of the same project that say the same thing as this one (CYRA-943). It compares stored
  # embeddings: no call to the AI service. A request without an embedding has no neighbours, so on an
  # installation without AI the answer is always empty.
  class FindSimilarRequests < ApplicationService
    TOP_K = 5
    # Same threshold as the duplicate suggestions of ideas and tickets.
    MAX_DISTANCE = 0.45

    def initialize(request:)
      @request = request
    end

    def call
      return Result.ok([]) if @request.embedding.blank?

      similar = @request.nearest_neighbors(:embedding, distance: "cosine")
                        .where(project_id: @request.project_id).where.not(status: :discarded)
                        .current_embedding.includes(:ticket).limit(TOP_K)
                        .select { |other| other.neighbor_distance <= MAX_DISTANCE }
      Result.ok(similar)
    end
  end
end
