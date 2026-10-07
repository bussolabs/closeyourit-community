require "rails_helper"

RSpec.describe Coworkers::Puck do
  let(:puck) { described_class.create!(account: create(:account), organization: create(:organization), name: "Researcher", instructions: "Cite sources") }

  it "bounds name, instructions and memory without accepting blank instructions" do
    puck.assign_attributes(name: "x" * 81, instructions: " ", memory: "x" * 8001)
    expect(puck).not_to be_valid
    expect(puck.errors.attribute_names).to include(:name, :instructions, :memory)
  end

  it "copies only the current Puck's bounded history and approved memory" do
    puck.update!(memory: "Approved note")
    9.times { |i| puck.runs.create!(kind: "chat", input: "Question #{i}", output: "x" * 7000, status: "completed") }
    context = puck.context_for("chat", "Next")
    expect(context[:history].size).to eq(8)
    expect(context[:history].first[:input]).to eq("Question 1")
    expect(context[:history].last[:output].size).to eq(6000)
    expect(context[:approvedMemory]).to eq("Approved note")
  end

  it "tells the model what became of the actions an earlier answer proposed" do
    run = puck.runs.create!(kind: "chat", input: "Create it", output: "Ready.", status: "completed")
    Assistant::Proposal.create!(coworkers_run: run, organization: puck.organization, account: puck.account, kind: :create_ticket,
                                status: :confirmed, payload: { "title" => "Footer broken" })
    actions = puck.context_for("chat", "Next")[:history].last[:actions]
    expect(actions).to eq([ { kind: "create_ticket", subject: "Footer broken", status: "confirmed" } ])
  end

  it "tells the model what the Puckies it handed work to answered" do
    run = puck.runs.create!(kind: "chat", input: "Ask Analyst", output: "Handed off.", status: "completed")
    helper = described_class.create!(account: puck.account, organization: puck.organization, name: "Analyst", instructions: "Read")
    helper.runs.create!(kind: "task", input: "From Researcher: list", output: "Open: STR-1", status: "completed", parent_run: run)
    handoffs = puck.context_for("chat", "Next")[:history].last[:handoffs]
    expect(handoffs).to eq([ { puck: "Analyst", status: "completed", output: "Open: STR-1" } ])
  end

  # Organization-wide capacity is CYRA-1027 (spec/services/coworkers/autonomy_spec.rb); a Puck keeps one lane per kind.
  it "allows a chat alongside a task but refuses a second run in the same lane" do
    Coworkers::Start.call(puck: puck, kind: "task", input: "Research")
    expect { Coworkers::Start.call(puck: puck, kind: "task", input: "Research again") }.to raise_error(Coworkers::Start::Busy)
    Coworkers::Start.call(puck: puck, kind: "chat", input: "Discuss")
    expect { Coworkers::Start.call(puck: puck, kind: "chat", input: "Discuss again") }.to raise_error(Coworkers::Start::Busy)
  end

  it "isolates realtime stream names by organization, owner, Puck and language" do
    stream = Realtime::Streams.coworker(puck, :en)
    expect(stream).to include(puck.organization_id, puck.account_id, puck.id)
    expect(stream).not_to eq(Realtime::Streams.coworker(puck, :it))
  end
end
