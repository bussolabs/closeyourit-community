require "rails_helper"

RSpec.describe Coworkers::SlackEventJob do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:link) { Coworkers::SlackLink.create!(slack_team_id: "T1", slack_user_id: "U1", account: account, organization: organization) }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(Coworkers::Slack).to receive(:post)
    allow(Coworkers::Slack).to receive(:thread_text).and_return("")
  end

  def payload(event_id: SecureRandom.hex(4), **event)
    { "team_id" => "T1", "event_id" => event_id,
      "event" => { "type" => "message", "user" => "U1", "channel" => "D1", "ts" => "1.1" }.merge(event.stringify_keys) }
  end

  it "ignores messages written by a bot" do
    link
    described_class.perform_now(payload(text: "hello", bot_id: "B1"))
    expect(Coworkers::Slack).not_to have_received(:post)
    expect(Coworkers::Run.count).to eq(0)
  end

  it "handles the same event only once" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    event = payload(event_id: "E1", text: "hello")
    2.times { described_class.perform_now(event) }
    expect(Coworkers::Slack).to have_received(:post).once
  end

  it "says no Puck is available when the person sees none" do
    link
    described_class.perform_now(payload(text: "hello"))
    expect(Coworkers::Slack).to have_received(:post).with(channel: "D1", thread_ts: "1.1", text: I18n.t("member.coworkers.slack.no_puck"))
    expect(Coworkers::Run.count).to eq(0)
  end

  it "asks the Puck used last with the whole text and the thread it was called into" do
    puck = Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help")
    link
    allow(Coworkers::Slack).to receive(:thread_text).with(channel: "C1", thread_ts: "0.9").and_return("Earlier: checkout is down")
    described_class.perform_now(payload(text: "what now?", channel: "C1", ts: "1.2", thread_ts: "0.9"))
    run = puck.runs.sole
    expect(run.input).to eq("what now?\n\nSlack thread:\nEarlier: checkout is down")
    expect(run.channel_ref).to eq("channel" => "C1", "thread_ts" => "0.9")
    expect(link.reload.puck_id).to eq(puck.id)
  end
end
