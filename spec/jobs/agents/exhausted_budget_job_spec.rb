# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::ExhaustedBudgetJob do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  it "settles the run whose attempts ran out" do
    workflow.update!(blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "attempt_limit",
                     blocked_reason: "attempt_limit: autopilot failed 2 times")

    described_class.perform_now(workflow.id)

    expect(ticket.reload.agent_workflow.budget_restart_engine).to be_present
  end

  # A person may have cancelled the run, or another path may have settled it, between the stop and
  # this job: nothing left to do is not a failure.
  it "does nothing when the run is gone" do
    id = workflow.id
    workflow.destroy!

    expect { described_class.perform_now(id) }.not_to raise_error
  end
end
