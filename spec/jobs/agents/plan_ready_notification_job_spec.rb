# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::PlanReadyNotificationJob, type: :job do
  let(:organization) { create(:organization) }
  let(:cto) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }
  let(:plan) do
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano pronto", scenarios: [ "Modifica" ],
                         definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")
  end

  before do
    create(:membership, account: cto, organization:, role: :owner)
    organization.update!(cto:)
  end

  it "crea notifiche in-app ed email idempotenti per il CTO effettivo" do
    expect do
      described_class.perform_now(plan.id)
      described_class.perform_now(plan.id)
    end.to change(Alerting::Notification, :count).by(2)

    expect(Alerting::Notification.where(account: cto).pluck(:via)).to contain_exactly("in_app", "email")
    expect(Alerting::Notification.where(account: cto).pluck(:title).uniq).to eq(
      [ "#{ticket.code}: piano v1 pronto per approvazione" ]
    )
  end

  it "non notifica un CTO che ha perso la visibilità del progetto" do
    organization.memberships.find_by!(account: cto).destroy!

    expect { described_class.perform_now(plan.id) }.not_to change(Alerting::Notification, :count)
  end
end
