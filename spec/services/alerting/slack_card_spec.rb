# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::SlackCard do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:rule) { create(:alerting_rule, organization:, name: "Nuovi errori") }
  let(:message) { create(:alerting_slack_message, organization:, project:, rule:) }

  def action_ids(card) = card.blocks.find { _1[:type] == "actions" }&.dig(:elements)&.pluck(:action_id)

  def status_text(card) = card.blocks.find { _1[:type] == "context" }[:elements].pluck(:text).join("\n")

  it "carries the three buttons while the alert is open" do
    expect(action_ids(described_class.new(message))).to eq(%w[alert_claim alert_mute alert_ticket])
  end

  it "sends to the alert's page when the alert cannot become a ticket" do
    monitor = create(:uptime_monitor, project:)
    message.update!(subject: create(:uptime_incident, monitor:), event_type: "uptime_down", url: "/member/monitoring/incidents/1")

    third = described_class.new(message).blocks.find { _1[:type] == "actions" }[:elements].last
    expect(third).to include(action_id: "alert_open", url: "#{App::Host.base_url}/member/monitoring/incidents/1")
  end

  it "says who silenced which rule and until when" do
    person = create(:account, name: "Ada Lovelace")
    message.update!(muted_by: person, muted_until: 1.hour.from_now)

    text = status_text(described_class.new(message))
    expect(text).to include("Ada Lovelace", "Nuovi errori", "<!date^#{message.muted_until.to_i}^")
  end

  it "shows who took the alert and the ticket opened" do
    person = create(:account, name: "Grace Hopper").tap { |a| create(:membership, account: a, organization:, role: :owner) }
    Types::InstallDefaults.call(organization:)
    ticket = Errors::PromoteToTicket.call(group: message.subject, reporter: person).value
    message.update!(claimed_by: person, ticket:, ticket_opened_by: person)

    card = described_class.new(message)
    expect(status_text(card)).to include("Grace Hopper", ticket.code)
    expect(card.blocks.find { _1[:type] == "actions" }[:elements].last).to include(action_id: "alert_open_ticket")
  end

  it "says the alert recovered and drops the buttons" do
    message.update!(status: :recovered, recovered_at: Time.current)

    card = described_class.new(message)
    expect(action_ids(card)).to be_nil
    expect(status_text(card)).to include("<!date^#{message.recovered_at.to_i}^")
  end

  it "escapes what Slack would read as markup" do
    message.update!(title: "Boom <script> & co")

    expect(described_class.new(message).blocks.first.dig(:text, :text)).to include("Boom &lt;script&gt; &amp; co")
  end
end
