require "rails_helper"

RSpec.describe Coworkers::Devices do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Ops", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "chat", input: "Go").tap { |r| r.update!(status: "running") } }
  let!(:device) do
    Coworkers::Device.issue(account: account, organization: organization, name: "Laptop").first.tap { |d| d.update!(last_seen_at: Time.current) }
  end

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
  end

  def result_of(call) = described_class.call(run, "computer_result", { "call_id" => call.id })

  it "keeps waiting while the person has not answered yet, then returns the answer" do
    allow(described_class).to receive(:sleep) { device.calls.sole.update!(status: "done", result: { "output" => "README.md" }) }
    expect(described_class.call(run, "computer_read_file", { "value" => "README.md" })).to eq(status: "done", output: "README.md")
    expect(described_class).to have_received(:sleep).with(0.5).once
  end

  it "reports a refusal of the person" do
    call = device.calls.create!(run: run, tool: "read_file", arguments: { "value" => "x" }, status: "denied")
    expect(result_of(call)).to eq(status: "denied", message: "The person said no on their computer.")
  end

  it "passes through any other final status" do
    call = device.calls.create!(run: run, tool: "read_file", arguments: { "value" => "x" }, status: "expired")
    expect(result_of(call)).to eq(status: "expired")
  end

  it "answers an unknown call id" do
    expect(described_class.call(run, "computer_result", { "call_id" => "missing" })).to eq(error: "Unknown computer call.")
  end
end
