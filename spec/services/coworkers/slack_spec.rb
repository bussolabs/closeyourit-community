require "rails_helper"

RSpec.describe Coworkers::Slack do
  before { allow(ENV).to receive(:[]).and_call_original }

  def configure(secret: "slack-test-secret", token: "xoxb-test")
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(secret)
    allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return(token)
  end

  describe ".verified?" do
    it "refuses every request when no signing secret is set" do
      configure(secret: nil)
      expect(described_class.verified?(timestamp: Time.current.to_i.to_s, signature: "v0=x", body: "{}")).to be(false)
    end

    it "refuses a timestamp that is not a number" do
      configure
      expect(described_class.verified?(timestamp: "soon", signature: "v0=x", body: "{}")).to be(false)
    end
  end

  describe ".thread_text" do
    it "reads only the people's messages of the thread" do
      configure
      stub_request(:post, "https://slack.com/api/conversations.replies")
        .with(headers: { "Authorization" => "Bearer xoxb-test" }, body: { channel: "C1", ts: "1.1", limit: 20 }.to_json)
        .to_return(body: { ok: true, messages: [ { text: "Checkout is down" }, { text: "Bot echo", bot_id: "B1" }, { text: "Since 9am" } ] }.to_json)
      expect(described_class.thread_text(channel: "C1", thread_ts: "1.1")).to eq("Checkout is down\nSince 9am")
    end

    it "calls nothing and reads an empty thread when Slack is not configured" do
      configure(token: nil)
      expect(described_class.thread_text(channel: "C1", thread_ts: "1.1")).to eq("")
      expect(a_request(:post, /slack\.com/)).not_to have_been_made
    end
  end

  # CYRA-1156 — the alert channels post with buttons, edit their message and answer privately.
  describe "alert messages" do
    let(:blocks) { [ { type: "section", text: { type: "mrkdwn", text: "*Down*" } } ] }

    before { configure }

    it "posts a message with blocks and returns where it lives" do
      stub_request(:post, "https://slack.com/api/chat.postMessage")
        .with(body: { channel: "C1", text: "Down", blocks: blocks }.to_json)
        .to_return(body: { ok: true, channel: "C1", ts: "1.5" }.to_json)
      expect(described_class.post_blocks(channel: "C1", text: "Down", blocks: blocks)).to include("ts" => "1.5")
    end

    it "sends the delivery id of a queued alert as message metadata (CYRA-1227)" do
      metadata = { event_type: "closeyourit_alert", event_payload: { delivery_id: "delivery-1" } }
      stub = stub_request(:post, "https://slack.com/api/chat.postMessage")
        .with(body: { channel: "C1", text: "Down", blocks: blocks, metadata: metadata }.to_json)
        .to_return(body: { ok: true, channel: "C1", ts: "1.5" }.to_json)
      described_class.post_blocks(channel: "C1", text: "Down", blocks: blocks, delivery_id: "delivery-1")
      expect(stub).to have_been_requested
    end

    it "edits a message in place" do
      stub = stub_request(:post, "https://slack.com/api/chat.update")
        .with(body: { channel: "C1", ts: "1.5", text: "Down", blocks: blocks }.to_json).to_return(body: { ok: true }.to_json)
      described_class.update(channel: "C1", ts: "1.5", text: "Down", blocks: blocks)
      expect(stub).to have_been_requested
    end

    it "answers only the person who clicked" do
      stub = stub_request(:post, "https://slack.com/api/chat.postEphemeral")
        .with(body: { channel: "C1", user: "U1", text: "No" }.to_json).to_return(body: { ok: true }.to_json)
      described_class.post_ephemeral(channel: "C1", user: "U1", text: "No")
      expect(stub).to have_been_requested
    end
  end
end
