# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SyncSkillReleasesJob do
  it "runs the sync and does not raise when it fails" do
    allow(Agents::SkillReleases::Sync).to receive(:call)
      .and_return(Result.err(AppError.new("down", code: "R502-AGENT-001", status: :bad_gateway)))

    expect { described_class.perform_now }.not_to raise_error
    expect(Agents::SkillReleases::Sync).to have_received(:call)
  end
end
