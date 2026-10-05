# frozen_string_literal: true

require "rails_helper"

# CYRA-147 — ramo org-scoped di Evaluate per le scadenze workload: subject = Workload::Action (team-scoped,
# nessun progetto), destinatari = i PARTECIPANTI della action, non tutta l'org né la flotta server.
RSpec.describe Alerting::Evaluate do
  let(:org) { create(:organization) }
  let(:team) { create(:team, organization: org) }
  let(:participant) { create(:account) }
  let(:action) do
    create(:workload_action, organization: org, team: team).tap do |a|
      create(:connections_workload_participant, action: a, account: participant)
    end
  end

  def evaluate
    described_class.call(
      event_type: "workload_due_soon", subject_type: "Workload::Action", subject_id: action.id,
      project_id: nil, organization_id: org.id
    )
  end

  it "con regola org → notifica in-app al partecipante, subject = action e project nil" do
    create(:alerting_rule, organization: org, event_type: :workload_due_soon, name: "Scadenze")

    result = evaluate

    expect(result.value).to be > 0
    notification = Alerting::Notification.find_by(account: participant, event_type: "workload_due_soon")
    expect(notification).to be_present
    expect(notification.subject).to eq(action)
    expect(notification.project).to be_nil
    expect(notification.organization).to eq(org)
  end

  it "senza regole per l'evento → nessuna consegna" do
    expect(evaluate.value).to eq(0)
  end

  # CYRA-241 difesa in profondità, come Alerting::Recipients#account_ids: se la rimozione dall'org lascia
  # dietro la partecipazione alla action, l'ex membro NON deve continuare a ricevere le scadenze.
  it "ESCLUDE un partecipante non più membro dell'organizzazione (partecipazione residua)" do
    create(:alerting_rule, organization: org, event_type: :workload_due_soon, name: "Scadenze")
    action # la partecipazione (e la membership) va creata PRIMA della rimozione: le `let` sono lazy
    Connections::Membership.where(account: participant, organization: org).delete_all

    result = evaluate

    expect(result.value).to eq(0)
    expect(Alerting::Notification.find_by(account: participant, event_type: "workload_due_soon")).to be_nil
  end

  it "non notifica chi non partecipa alla action (team-scoped, non org-wide)" do
    create(:alerting_rule, organization: org, event_type: :workload_due_soon, name: "Scadenze")
    stranger = create(:account)
    create(:membership, account: stranger, organization: org, role: :owner)

    evaluate

    expect(Alerting::Notification.find_by(account: stranger, event_type: "workload_due_soon")).to be_nil
    expect(Alerting::Notification.find_by(account: participant, event_type: "workload_due_soon")).to be_present
  end
end
