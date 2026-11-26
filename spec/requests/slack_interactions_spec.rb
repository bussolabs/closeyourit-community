# frozen_string_literal: true

require "rails_helper"

# CYRA-1156 — button clicks on the Slack alerts: Slack's signature first, then a job.
RSpec.describe "Slack interactions", type: :request do
  include ActiveJob::TestHelper

  let(:signing_secret) { "slack-test-secret" }
  let(:organization) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) } }
  let(:message) { create(:alerting_slack_message, organization:) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(signing_secret)
    allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-test")
    allow(Coworkers::Slack).to receive(:post_ephemeral)
    allow(Coworkers::Slack).to receive(:update).and_return({ "ok" => true })
  end

  def payload(action_id: "alert_claim", action_ts: "1700000001.000001")
    { type: "block_actions", team: { id: "T1" }, user: { id: "U1", team_id: "T1" },
      container: { type: "message", channel_id: message.slack_channel, message_ts: message.slack_ts },
      actions: [ { action_id: action_id, action_ts: action_ts } ] }
  end

  def click(data, timestamp: Time.current.to_i, secret: signing_secret)
    body = URI.encode_www_form(payload: data.to_json)
    signature = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{body}")
    post "/slack/interactions", params: body, headers: { "Content-Type" => "application/x-www-form-urlencoded",
                                                         "X-Slack-Request-Timestamp" => timestamp.to_s, "X-Slack-Signature" => signature }
  end

  it "refuses a request that Slack did not sign, and changes nothing" do
    click(payload, secret: "wrong")
    expect(response).to have_http_status(:not_found)
    click(payload, timestamp: 1.hour.ago.to_i)
    expect(response).to have_http_status(:not_found)

    expect(enqueued_jobs).to be_empty
    expect(message.reload.version).to eq(1)
  end

  it "answers at once and queues the click" do
    click(payload)

    expect(response).to have_http_status(:ok)
    expect(Alerting::SlackActionJob).to have_been_enqueued.with(
      "team_id" => "T1", "user_id" => "U1", "channel" => message.slack_channel, "ts" => message.slack_ts,
      "action" => "alert_claim", "action_ts" => "1700000001.000001"
    )
  end

  it "ignores the link buttons, which only open a page" do
    click(payload(action_id: "alert_open"))

    expect(response).to have_http_status(:ok)
    expect(enqueued_jobs).to be_empty
  end

  it "takes the alert for the linked person, and the same click delivered twice acts once" do
    Coworkers::SlackLink.create!(slack_team_id: "T1", slack_user_id: "U1", account: owner, organization:)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

    perform_enqueued_jobs { 2.times { click(payload) } }

    expect(message.reload).to have_attributes(claimed_by_id: owner.id, version: 2, rendered_version: 2)
    expect(message.subject.reload.assignee).to eq(owner)
    expect(Coworkers::Slack).to have_received(:update).once
  end
end
