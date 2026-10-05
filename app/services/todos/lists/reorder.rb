# frozen_string_literal: true

module Todos
  module Lists
    # Riordina le liste dell'account nell'org secondo l'ordine di ordered_ids (posizione = indice).
    # Idempotente e anti-BOLA: agisce solo sulle liste possedute; gli id sconosciuti sono ignorati.
    class Reorder < ApplicationService
      def initialize(account:, organization:, ordered_ids:)
        @account = account
        @organization = organization
        @ordered_ids = Array(ordered_ids).map(&:to_s)
      end

      def call
        scope = Todos::List.for(account: @account, organization: @organization)
        by_id = scope.where(id: @ordered_ids).index_by { |list| list.id.to_s }
        @ordered_ids.each_with_index do |id, index|
          by_id[id]&.update_column(:position, index)
        end
        Result.ok
      end
    end
  end
end
