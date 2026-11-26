# frozen_string_literal: true

require "rails_helper"

# CYRA-1156 — every refresh carries its version: one older than the latest change, or than the last
# one written to Slack, is dropped, so two quick clicks never leave the message on the old state.
RSpec.describe Alerting::SlackRefreshJob do
  let(:message) { create(:alerting_slack_message, version: 3, rendered_version: 1) }

  before { allow(Coworkers::Slack).to receive(:update).and_return({ "ok" => true }) }

  it "drops a refresh older than the latest change" do
    described_class.perform_now(message.id, 2)

    expect(Coworkers::Slack).not_to have_received(:update)
    expect(message.reload.rendered_version).to eq(1)
  end

  it "writes the latest version and then drops a repeat of it" do
    2.times { described_class.perform_now(message.id, 3) }

    expect(Coworkers::Slack).to have_received(:update)
      .with(hash_including(channel: message.slack_channel, ts: message.slack_ts)).once
    expect(message.reload.rendered_version).to eq(3)
  end

  it "keeps the version unwritten when Slack refuses, so a later change can try again" do
    allow(Coworkers::Slack).to receive(:update).and_return({ "ok" => false, "error" => "channel_not_found" })

    described_class.perform_now(message.id, 3)

    expect(message.reload.rendered_version).to eq(1)
  end

  it "removes the buttons once the alert recovered" do
    message.update!(status: :recovered, recovered_at: Time.current)

    described_class.perform_now(message.id, 3)

    without_buttons = satisfy { |blocks| blocks.none? { _1[:type] == "actions" } }
    expect(Coworkers::Slack).to have_received(:update).with(hash_including(blocks: without_buttons))
  end
end
