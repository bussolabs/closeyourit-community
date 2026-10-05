# frozen_string_literal: true

module Analytics
  module Goals
    # Crea un goal (conversione) su un progetto. Validazioni sul model; errore di dominio GOAL.
    class Save < ApplicationService
      def initialize(project:, attributes:)
        @project = project
        @attributes = attributes
      end

      def call
        goal = @project.analytics_goals.new(@attributes)
        return Result.ok(goal) if goal.save

        Result.err(AppError.new(
          goal.errors.full_messages.to_sentence.presence || "Goal non valido",
          code: "R422-GOAL-001", details: goal.errors.as_json
        ))
      end
    end
  end
end
