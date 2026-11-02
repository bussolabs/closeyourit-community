# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Council::WorkChoice do
  let(:organization) { create(:organization) }
  let(:host) do
    create(:agent_host, organization:, runtimes: [ { "name" => "claude", "present" => true },
                                                  { "name" => "codex", "present" => true } ])
  end
  let(:ticket) { create(:ticket, organization:) }

  it "returns nothing for a ticket the council did not open" do
    expect(described_class.for(ticket:, host:)).to be_nil
  end

  it "returns the council's engine and model with the other engine as reviewer" do
    create(:agent_council_proposal, ticket:, outcome: "ticket", suggested_engine: "codex", suggested_model: "gpt-6-astra")
    expect(described_class.for(ticket:, host:).to_h).to eq(engine: "codex", model: "gpt-6-astra", reviewer: "claude")
  end

  it "returns nothing when the machine lacks the engine" do
    host.update!(runtimes: [ { "name" => "claude", "present" => true } ])
    create(:agent_council_proposal, ticket:, outcome: "ticket", suggested_engine: "codex")
    expect(described_class.for(ticket:, host:)).to be_nil
  end
end
