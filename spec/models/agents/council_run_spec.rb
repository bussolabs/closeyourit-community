# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::CouncilRun do
  it "accepts only known statuses" do
    expect(build(:agent_council_run, status: "paused")).not_to be_valid
  end

  it "keeps its proposals" do
    run = create(:agent_council_run)
    proposal = create(:agent_council_proposal, council_run: run)
    expect(run.proposals).to contain_exactly(proposal)
  end

  it "lists the tickets the council opened in an organization" do
    proposal = create(:agent_council_proposal)
    ticket = create(:ticket, organization: proposal.organization, project: proposal.project)
    proposal.update!(ticket:, outcome: "ticket")
    expect(Agents::CouncilProposal.ticket_ids_for(proposal.organization).to_a).to eq([ ticket.id ])
  end

  it "keeps a proposal when its ticket is deleted" do
    proposal = create(:agent_council_proposal)
    ticket = create(:ticket, organization: proposal.organization, project: proposal.project)
    proposal.update!(ticket:, outcome: "ticket")
    ticket.destroy!
    expect(proposal.reload.ticket_id).to be_nil
  end
end
