# frozen_string_literal: true

module Agents
  # CYRA-1327 — settles a piece of work whose attempts ran out: over once on another engine, set aside
  # the second time (Agents::Workflows::ExhaustedBudget).
  #
  # A job, and not a call in place, because the cap is counted INSIDE the delivery transaction, with
  # the run and its attempts under lock — and starting over destroys both, so the delivery would go on
  # holding rows that no longer exist. Enqueued after the commit, so the stop it reads is written.
  #
  # The run may be gone by the time this starts (a person cancelled it, or another path already
  # settled it): then there is nothing to do, and that is not a failure.
  #
  # `digest` is the state the settlement was decided on. The service reads it again under the lock and
  # does nothing if anything moved meanwhile — a person's retry on that stop, an approval of the plan,
  # a cancel. Without it the job would destroy a run that had just gone back to work.
  class ExhaustedBudgetJob < ApplicationJob
    queue_as :maintenance

    def perform(workflow_id, digest = nil)
      workflow = Agents::Workflow.find_by(id: workflow_id)
      return if workflow.nil?

      Agents::Workflows::ExhaustedBudget.call(workflow: workflow, digest: digest)
    end
  end
end
