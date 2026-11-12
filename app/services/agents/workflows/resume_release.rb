# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1285 — a run cancelled between staging and production goes back to its closers, from where it
    # stopped: the cancellation is lifted and production follows its usual hold. The ticket history
    # keeps both the cancel and the resume.
    class ResumeRelease < ApplicationService
      def initialize(workflow:, actor:)
        @workflow = workflow
        @actor = actor
      end

      def call
        resumed = ApplicationRecord.transaction do
          @workflow.lock!
          next false unless @workflow.release_interrupted?

          @workflow.update!(cancelled_at: nil, cancelled_by: nil, cancellation_reason: nil)
          Ticketing::RecordActivity.call(ticket: @workflow.ticket, actor: @actor, action: "release_resumed", data: {})
          true
        end
        resumed ? Result.ok(@workflow) : not_interrupted
      end

      private

      def not_interrupted
        Result.err(AppError.new(I18n.t("member.tickets.errors.release_not_interrupted"),
                                code: "R409-WORKFLOW-017", status: :conflict))
      end
    end
  end
end
