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

  it "allows a chat alongside a task but refuses a third run and another browser lane" do
    other = described_class.create!(account: puck.account, organization: puck.organization, name: "Other", instructions: "Cite sources")
    Coworkers::Start.call(puck: puck, kind: "task", input: "Research")
    expect { Coworkers::Start.call(puck: other, kind: "task", input: "Research") }.to raise_error(Coworkers::Start::Busy)
    Coworkers::Start.call(puck: puck, kind: "chat", input: "Discuss")
    expect { Coworkers::Start.call(puck: other, kind: "chat", input: "Discuss") }.to raise_error(Coworkers::Start::Busy)
  end

  it "isolates realtime stream names by organization, owner, Puck and language" do
    stream = Realtime::Streams.coworker(puck, :en)
    expect(stream).to include(puck.organization_id, puck.account_id, puck.id)
    expect(stream).not_to eq(Realtime::Streams.coworker(puck, :it))
  end
end
