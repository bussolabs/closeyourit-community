# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Proposal do
  it "belongs to the reply and starts pending" do
    proposal = create(:assistant_proposal)

    expect(proposal).to be_status_pending
    expect(proposal.message.proposals).to eq([ proposal ])
  end

  it "is confirmable while pending or failed only" do
    proposal = build(:assistant_proposal)

    expect(proposal).to be_confirmable
    proposal.status = :failed
    expect(proposal).to be_confirmable
    %i[running confirmed discarded].each do |status|
      proposal.status = status
      expect(proposal).not_to be_confirmable
    end
  end

  it "requires a payload" do
    expect(build(:assistant_proposal, payload: {})).not_to be_valid
  end

  it "rejects an organization different from the reply's" do
    expect(build(:assistant_proposal, organization: create(:organization))).not_to be_valid
  end
end
