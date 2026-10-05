# frozen_string_literal: true

module Secrets
  module Versions
    # Crea una versione immutabile col valore CORRENTE della variabile (già salvato). Chiamato da
    # Variables::Set quando il plaintext cambia. `number` monotòno per variabile.
    class Snapshot < ApplicationService
      def initialize(variable:, actor: nil)
        @variable = variable
        @actor = actor
      end

      def call
        number = @variable.versions.maximum(:number).to_i + 1
        @variable.versions.create!(number:, value: @variable.value, created_by: @actor)
      end
    end
  end
end
