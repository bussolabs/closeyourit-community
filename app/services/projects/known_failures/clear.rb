# frozen_string_literal: true

module Projects
  module KnownFailures
    # Removes the known-failure mark of a test (CYRA-1165): its next failures arrive as new again.
    # Clearing a test that has no mark is a no-op; the gesture lands in the project history.
    class Clear < ApplicationService
      def initialize(test_case:, actor:, true_actor: nil)
        @test_case = test_case
        @actor = actor
        @true_actor = true_actor
      end

      def call
        known = @test_case.known_failure
        return Result.ok(nil) if known.nil?

        ApplicationRecord.transaction do
          known.destroy!
          Activity::Record.call(subject: @test_case.project, action: "updated", actor: @actor, true_actor: @true_actor,
                                data: { fields: [ "known_failure_cleared" ], test: @test_case.name.first(200) })
        end
        Result.ok(nil)
      end
    end
  end
end
