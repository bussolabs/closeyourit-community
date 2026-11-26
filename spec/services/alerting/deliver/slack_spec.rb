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

  it "keeps nothing when Slack refuses the message" do
    allow(Coworkers::Slack).to receive(:post_blocks).and_return({ "ok" => false, "error" => "not_in_channel" })

    expect(deliver.error.code).to eq("R502-ALERT-003")
    expect(Alerting::SlackMessage.count).to eq(0)
  end

  it "intercepts the test lab, as the webhook does" do
    allow(DevelopmentLab).to receive(:organization?).with(organization).and_return(true)
    allow(Coworkers::Slack).to receive(:post_blocks)

    expect(deliver.value).to eq(:lab_intercepted)
    expect(Coworkers::Slack).not_to have_received(:post_blocks)
  end
end
