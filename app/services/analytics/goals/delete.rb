# frozen_string_literal: true

module Analytics
  module Goals
    # Elimina un goal. Idempotente lato chiamante (il controller scope-a al progetto visibile).
    class Delete < ApplicationService
      def initialize(goal:)
        @goal = goal
      end

      def call
        @goal.destroy
        Result.ok(true)
      end
    end
  end
end
