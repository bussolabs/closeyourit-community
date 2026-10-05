# frozen_string_literal: true

module Product
  module Features
    # Elimina una funzionalità e con lei le sue celle (dependent: :destroy). A differenza della
    # categoria non serve svuotarla prima: le celle sono attributi della riga, non contenuto
    # autonomo, e non esiste un modo di "spostarle" altrove.
    class Destroy < ApplicationService
      def initialize(feature:)
        @feature = feature
      end

      def call
        @feature.destroy
        Result.ok(@feature)
      end
    end
  end
end
