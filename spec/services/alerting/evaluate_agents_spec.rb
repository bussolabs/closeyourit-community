# frozen_string_literal: true

require "rails_helper"

# CYRA-212 — branch org-scoped di Evaluate per l'allarme agents_stalled: subject = l'organizzazione, nessun
# progetto, recipients instradati su chi gestisce l'automazione (agents.view/manage), NON la flotta server.
RSpec.describe Alerting::Evaluate do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def evaluate
    described_class.call(
      event_type: "agents_stalled", subject_type: "Organizations::Organization", subject_id: org.id,
      project_id: nil, organization_id: org.id
    )
  end

  it "con regola org → notifica in-app all'owner, subject = org e project nil" do
    create(:alerting_rule, organization: org, event_type: :agents_stalled, name: "A vuoto")

    result = evaluate

    expect(result.value).to be > 0
    notification = Alerting::Notification.find_by(account: owner, event_type: "agents_stalled")
    expect(notification).to be_present
    expect(notification.subject).to eq(org)
    expect(notification.project).to be_nil
    expect(notification.organization).to eq(org)
  end

  it "senza regole per l'evento → nessuna consegna" do
    expect(evaluate.value).to eq(0)
  end

  it "instrada i destinatari sul permesso agenti, non su quello dei server" do
    create(:alerting_rule, organization: org, event_type: :agents_stalled, name: "A vuoto")
    role = create(:role, organization: org, name: "Automation")
    create(:role_permission, role: role, permission_key: "agents.view")
    automation_member = create(:account)
    create(:membership, account: automation_member, organization: org, role: :member)
    create(:account_role, account: automation_member, organization: org, role: role)

    server_role = create(:role, organization: org, name: "Infra")
    create(:role_permission, role: server_role, permission_key: "servers.view")
    server_member = create(:account)
    create(:membership, account: server_member, organization: org, role: :member)
    create(:account_role, account: server_member, organization: org, role: server_role)

    evaluate

    expect(Alerting::Notification.find_by(account: automation_member, event_type: "agents_stalled")).to be_present
    expect(Alerting::Notification.find_by(account: server_member, event_type: "agents_stalled")).to be_nil
  end

  # CYRA-282 — l'allarme per-host (subject = Agents::Host) percorre lo stesso branch org-scoped: la regola
  # org lo intercetta, il destinatario è chi gestisce l'automazione, il subject della notifica è la macchina.
  it "con regola org → notifica in-app per l'host in errore, subject = l'host" do
    host = create(:agent_host, organization: org, hostname: "minion-1.local")
    create(:alerting_rule, organization: org, event_type: :agents_host_failing, name: "Macchina in errore")

    result = described_class.call(
      event_type: "agents_host_failing", subject_type: "Agents::Host", subject_id: host.id,
      project_id: nil, organization_id: org.id
    )

    expect(result.value).to be > 0
    notification = Alerting::Notification.find_by(account: owner, event_type: "agents_host_failing")
    expect(notification).to be_present
    expect(notification.subject).to eq(host)
    expect(notification.project).to be_nil
  end
end
