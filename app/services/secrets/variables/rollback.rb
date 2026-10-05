# frozen_string_literal: true

module Secrets
  module Variables
    # Ripristina il valore di una variabile a quello di una sua versione precedente. Delega a Set (che
    # crea a sua volta una nuova versione — il rollback è esso stesso un cambio — audita e sincronizza).
    class Rollback < ApplicationService
      def initialize(variable:, version:, actor: nil)
        @variable = variable
        @version = version
        @actor = actor
      end

      def call
        if @version.secret_variable_id != @variable.id
          return Result.err(AppError.new("La versione non appartiene a questo secret", code: "R422-SECRET-003"))
        end

        Set.call(project: @variable.project, environment: @variable.environment,
                 name: @variable.name, value: @version.value, actor: @actor)
      end
    end
  end
end
