# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::ExecuteJob do
  it "runs the move" do
    move = create(:project_move)
    allow(Projects::Moves::Execute).to receive(:call).and_return(Result.ok(move))

    described_class.perform_now(move.id)

    expect(Projects::Moves::Execute).to have_received(:call).with(move:)
  end

  it "ignores a move that is no longer pending" do
    move = create(:project_move, status: :succeeded)
    allow(Projects::Moves::Execute).to receive(:call)

    described_class.perform_now(move.id)

    expect(Projects::Moves::Execute).not_to have_received(:call)
  end

  it "expires stale moves before running" do
    stale = create(:project_move, status: :running)
    stale.update_columns(updated_at: 20.minutes.ago)
    allow(Projects::Moves::Execute).to receive(:call)

    described_class.perform_now(stale.id)

    expect(stale.reload).to be_failed
  end
end
