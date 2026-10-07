require "rails_helper"

RSpec.describe Coworkers::Session do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Ops", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "task", input: "Go").tap { |r| r.update!(status: "running") } }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
  end

  it "treats arguments that are not a hash as empty" do
    run.update!(control: "person", control_steps: [ { "id" => "s1", "action" => "point" } ])
    expect(described_class.call(run, "control", nil)).to eq(control: "person", steps: [ { "id" => "s1", "action" => "point" } ])
  end

  it "stores the proof video" do
    webm = Base64.strict_encode64("\x1A\x45\xDF\xA3fake".b)
    expect(described_class.call(run, "attach", { "kind" => "video", "data" => webm })).to eq(status: "attached")
    expect(run.reload.video).to be_attached
    expect(run.video.filename.to_s).to eq("proof-#{run.id}.webm")
    expect(run.screen).not_to be_attached
  end

  it "refuses a video larger than its limit" do
    stub_const("Coworkers::Session::MAX_VIDEO", 8)
    webm = Base64.strict_encode64("\x1A\x45\xDF\xA3too-long".b)
    expect(described_class.call(run, "attach", { "kind" => "video", "data" => webm })).to eq(error: "invalid_attachment")
  end
end
