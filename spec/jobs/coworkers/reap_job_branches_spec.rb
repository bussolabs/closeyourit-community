# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coworkers::ReapJob do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:puck) { new_puck }

  # One Puck has at most one active run per kind.
  def new_puck = Coworkers::Puck.create!(account: account, organization: organization, name: "Researcher", instructions: "Cite sources")

  before { allow(Coworkers).to receive(:enabled?).and_return(true) }

  it "does nothing when runs execute locally" do
    allow(Coworkers).to receive(:remote?).and_return(false)
    run = puck.runs.create!(kind: "chat", input: "Hello", stop_requested: true)
    described_class.perform_now
    expect(run.reload.status).to eq("queued")
  end

  it "stops runs asked to stop and interrupts stale queued runs" do
    allow(Coworkers).to receive(:remote?).and_return(true)
    stopped = puck.runs.create!(kind: "chat", input: "Stop", stop_requested: true)
    stale = new_puck.runs.create!(kind: "chat", input: "Stale", created_at: 10.minutes.ago)
    fresh = new_puck.runs.create!(kind: "chat", input: "Fresh")
    described_class.perform_now
    expect(stopped.reload).to have_attributes(status: "stopped", error_code: nil)
    expect(stale.reload).to have_attributes(status: "interrupted", error_code: "runtime_interrupted")
    expect(fresh.reload.status).to eq("queued")
  end
end
