# frozen_string_literal: true

module Guidance
  # Riordina gli elementi di guidance (references o procedures) di UN owner secondo ordered_ids
  # (posizione = indice). Idempotente e anti cross-owner: `collection` è già scoped all'owner, gli id
  # estranei non vi rientrano e vengono ignorati (anti-BOLA). Come Todos::Items::Reorder.
  class Reorder < ApplicationService
    def initialize(collection:, ordered_ids:)
      @collection = collection
      @ordered_ids = Array(ordered_ids).map(&:to_s)
    end

    def call
      by_id = @collection.where(id: @ordered_ids).index_by { |record| record.id.to_s }
      @ordered_ids.each_with_index do |id, index|
        by_id[id]&.update_column(:position, index)
      end
      Result.ok
    end
  end
end
