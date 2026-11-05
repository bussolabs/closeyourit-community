# frozen_string_literal: true

module Analytics
  module EventDefinitions
    # Creates a declared event on a project, or updates the one given (CYRA-1158). Rules live on the model.
    class Save < ApplicationService
      def initialize(project:, attributes:, definition: nil)
        @project = project
        @attributes = attributes
        @definition = definition
      end

      def call
        definition = @definition || @project.analytics_event_definitions.new
        definition.assign_attributes(@attributes)
        return Result.ok(definition) if definition.save

        Result.err(AppError.new(
          definition.errors.full_messages.to_sentence.presence || "Invalid event definition",
          code: "R422-EVENTDEF-001", details: definition.errors.as_json
        ))
      end
    end
  end
end
