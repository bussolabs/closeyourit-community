# frozen_string_literal: true

module Todos
  module Items
    # Riordina le voci DENTRO una lista secondo ordered_ids (posizione = indice). Idempotente e
    # anti cross-lista: agisce solo sulle voci della lista data; gli id estranei sono ignorati.
    class Reorder < ApplicationService
      def initialize(list:, ordered_ids:)
        @list = list
        @ordered_ids = Array(ordered_ids).map(&:to_s)
      end

      def call
        by_id = @list.items.where(id: @ordered_ids).index_by { |item| item.id.to_s }
        @ordered_ids.each_with_index do |id, index|
          by_id[id]&.update_column(:position, index)
        end
        Result.ok
      end
    end
  end
end
