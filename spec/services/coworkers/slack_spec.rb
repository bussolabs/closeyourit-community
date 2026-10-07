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
end
