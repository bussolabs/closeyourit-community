# frozen_string_literal: true

module Product
  module Cells
    # Azzera una cella: l'incrocio torna "non impostato" (il trattino nella matrice), che è diverso
    # da "non previsto" — quello è uno stato esplicito. Idempotente: azzerare una cella già vuota
    # non è un errore.
    class Clear < ApplicationService
      def initialize(feature:, platform:)
        @feature = feature
        @platform = platform
      end

      def call
        cell = ::Connections::FeaturePlatform.find_by(feature: @feature, platform: @platform)
        cell&.destroy
        Result.ok(cell)
      end
    end
  end
end
