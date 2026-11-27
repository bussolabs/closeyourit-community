# frozen_string_literal: true

require "rails_helper"

# CYRA-1156 — the Slack app channel: the alert with three buttons, remembered for later changes.
RSpec.describe Notifications::Deliver::Slack do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:channel) { create(:alerting_channel, :slack_app, organization:) }
  let(:rule) { create(:alerting_rule, organization:) }
  let(:group) { create(:error_group, project:) }
  let(:content) { Alerting::Content.new(title: "Nuovo errore · boom", body: "in checkout", url: "/member/monitoring/error/1", project:) }

  def deliver = Alerting::Deliver.slack(channel:, rule:, event_type: "error_new", subject: group, content:)

  it "posts the alert with its three buttons and remembers where the message lives" do
    allow(Coworkers::Slack).to receive(:post_blocks).and_return({ "ok" => true, "channel" => "C0123ABCD", "ts" => "1700000000.000100" })

    expect(deliver).to be_ok

    three_buttons = satisfy do |blocks|
      blocks.find { _1[:type] == "actions" }[:elements].pluck(:action_id) == %w[alert_claim alert_mute alert_ticket]
    end
    expect(Coworkers::Slack).to have_received(:post_blocks).with(hash_including(channel: "C0123ABCD", blocks: three_buttons))
    expect(Alerting::SlackMessage.sole).to have_attributes(
      slack_ts: "1700000000.000100", rule_id: rule.id, subject: group, project_id: project.id, event_type: "error_new", version: 1
    )
  end

  it "keeps nothing when Slack refuses the message, and the refusal is definitive (CYRA-1227)" do
    allow(Coworkers::Slack).to receive(:post_blocks).and_return({ "ok" => false, "error" => "not_in_channel" })

    error = deliver.error
    expect(error.code).to eq("R422-ALERT-005")
    expect(TransientFailure === error).to be(false)
    expect(Alerting::SlackMessage.count).to eq(0)
  end

  it "asks for a retry when Slack is rate limiting (CYRA-1227)" do
    allow(Coworkers::Slack).to receive(:post_blocks).and_return({ "ok" => false, "error" => "ratelimited" })

    error = deliver.error
    expect(error.code).to eq("R502-ALERT-003")
    expect(TransientFailure === error).to be(true)
  end

  it "asks for a retry when Slack does not answer, but not when the app has no credentials (CYRA-1227)" do
    allow(Coworkers::Slack).to receive(:post_blocks).and_return(nil)
    allow(Coworkers::Slack).to receive(:configured?).and_return(true)
    expect(TransientFailure === deliver.error).to be(true)

    allow(Coworkers::Slack).to receive(:configured?).and_return(false)
    expect(deliver.error.code).to eq("R422-ALERT-005")
  end

  it "intercepts the test lab, as the webhook does" do
    allow(DevelopmentLab).to receive(:organization?).with(organization).and_return(true)
    allow(Coworkers::Slack).to receive(:post_blocks)

    expect(deliver.value).to eq(:lab_intercepted)
    expect(Coworkers::Slack).not_to have_received(:post_blocks)
  end
end
