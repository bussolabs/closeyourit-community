# frozen_string_literal: true

require "rails_helper"

# CYRA-1345 — a plan approved with a warning tells the effective CTO why, once.
RSpec.describe Agents::PlanWarningJob, type: :job do
  let(:organization) { create(:organization) }
  let(:cto) { create(:account, locale: "en") }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Retry a failed payment once", with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  def decision(outcome: "approved", reasons: %w[risk_above_threshold reserved_topic])
    Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                      target_digest: SecureRandom.hex(4), outcome:, engine: "codex", risk_score: 10,
                                      evidence: { "reasons" => reasons })
  end

  before do
    create(:membership, account: cto, organization:, role: :owner)
    organization.update!(cto:)
  end

  it "tells the effective CTO the risk and each reason, once" do
    warned = decision

    expect do
      described_class.perform_now(warned.id)
      described_class.perform_now(warned.id)
    end.to change { Alerting::Notification.where(account: cto, via: :in_app).count }.by(1)

    notice = Alerting::Notification.find_by!(account: cto, via: :in_app)
    expect(notice.subject).to eq(ticket)
    expect(notice.title).to eq("#{ticket.code}: plan approved with a warning (risk 10 out of 10)")
    expect(notice.body).to include("Retry a failed payment once", "the risk is above what an agent may decide alone",
                                   "it touches a reserved topic")
  end

  it "sends nothing for a plan approved with no reason" do
    expect { described_class.perform_now(decision(reasons: []).id) }.not_to change(Alerting::Notification, :count)
  end

  it "sends nothing for a plan that still waits for a person" do
    expect { described_class.perform_now(decision(outcome: "escalated").id) }.not_to change(Alerting::Notification, :count)
  end

  it "does not tell a CTO who lost sight of the project" do
    organization.memberships.find_by!(account: cto).destroy!

    expect { described_class.perform_now(decision.id) }.not_to change(Alerting::Notification, :count)
  end
end
