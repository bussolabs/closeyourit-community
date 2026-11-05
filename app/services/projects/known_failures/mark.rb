# frozen_string_literal: true

module Projects
  module KnownFailures
    # Marks a failing test as already known, with the ticket that will fix it and an expiry
    # (CYRA-1165). Marking it again replaces ticket and expiry. Who did it is kept on the row, like
    # the retirement of a release, and the gesture lands in the project history.
    class Mark < ApplicationService
      def initialize(test_case:, ticket:, expires_on:, actor:, true_actor: nil)
        @test_case = test_case
        @ticket = ticket
        @expires_on = expires_on
        @actor = actor
        @true_actor = true_actor
      end

      def call
        return failure("ticket_required") if @ticket.nil?
        return failure("expiry_invalid") unless expiry_within_reach?

        known = @test_case.known_failure || @test_case.build_known_failure(project: @test_case.project)
        ApplicationRecord.transaction do
          known.update!(ticket: @ticket, expires_on: @expires_on, marked_by: @actor)
          Activity::Record.call(subject: @test_case.project, action: "updated", actor: @actor, true_actor: @true_actor,
                                data: { fields: [ "known_failure_marked" ], test: @test_case.name.first(200),
                                        ticket: @ticket.code })
        end
        Result.ok(known)
      end

      private

      def expiry_within_reach?
        @expires_on.is_a?(Date) &&
          @expires_on.between?(Date.current, KnownFailure::MAX_VALIDITY.from_now.to_date)
      end

      def failure(key)
        Result.err(AppError.new(I18n.t("member.project_tests.known_failure.#{key}",
                                       days: KnownFailure::MAX_VALIDITY.in_days.to_i),
                                code: "R422-TESTRUN-010", status: :unprocessable_content))
      end
    end
  end
end
