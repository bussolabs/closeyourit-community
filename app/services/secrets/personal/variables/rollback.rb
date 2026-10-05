# frozen_string_literal: true

module Secrets
  module Personal
    module Variables
      # Ripristina il valore di una variabile a quello di una sua versione precedente. Delega a Set (che
      # crea a sua volta una nuova versione — il rollback è esso stesso un cambio — e audita).
      class Rollback < ApplicationService
        def initialize(variable:, version:)
          @variable = variable
          @version = version
        end

        def call
          if @version.variable_id != @variable.id
            return Result.err(AppError.new("La versione non appartiene a questo secret", code: "R422-PERSONALSECRET-003"))
          end

          Set.call(account: @variable.account, organization: @variable.organization,
                   name: @variable.name, value: @version.value)
        end
      end
    end
  end
end
