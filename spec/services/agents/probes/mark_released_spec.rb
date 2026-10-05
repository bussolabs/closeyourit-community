# frozen_string_literal: true

require "rails_helper"

# CYRA-624 — «segna come rilasciato»: per quando sai tu che è a posto e la macchina non riesce a
# vederlo. Non è una scorciatoia al controllo: è l'uscita quando il controllo non può rispondere, e
# resta scritto che quella volta «Fatto» l'ha detto una persona.
RSpec.describe Agents::Probes::MarkReleased do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end
  let!(:fatto) { create(:ticket_status, :done, organization:) }
  let(:in_progress) { create(:ticket_status, :in_progress, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_progress, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let!(:probe) do
    workflow.probes.create!(kind: "deploy_smoke", bound_at: 5.minutes.ago, next_check_at: 1.minute.ago,
                            expected: { "version" => "v0.30.0", "sha" => "a" * 40, "repo" => "x/y" })
  end

  before do
    organization.update!(cto:)
    pronta_per!(workflow, "closer_production")
    workflow.update!(closer_production_completed_at: Time.current)
  end

  it "porta il ticket a Fatto, chiude la prova e lascia scritto chi e quando" do
    esito = described_class.call(workflow:, actor: cto)

    expect(esito).to be_ok
    expect(ticket.reload.status).to eq(fatto)
    expect(workflow.reload.completed_at).to be_present
    expect(probe.reload.closed_at).to be_present
    expect(probe.evidence).to include("closed_by" => "human", "account_id" => cto.id)
  end

  # Chiusa la prova, nessun controllo successivo può più bloccare o far scadere una lavorazione che
  # una persona ha già chiuso.
  it "dopo il clic il controllo non può più bloccare né far scadere" do
    described_class.call(workflow:, actor: cto)
    probe.reload.update!(bound_at: 2.hours.ago)

    Agents::Probes::Observe.call(probe:, client: instance_double(Github::Client))

    expect(workflow.reload.blocked_at).to be_nil
  end

  it "premuto due volte non fa un secondo passaggio a Fatto né un secondo evento" do
    described_class.call(workflow:, actor: cto)
    prima = { eventi: ticket.reload.events.count, chiuso: probe.reload.evidence["at"],
              concluso: workflow.reload.completed_at }

    expect(described_class.call(workflow:, actor: cto)).to be_ok

    expect(ticket.reload.events.count).to eq(prima[:eventi])
    expect(probe.reload.evidence["at"]).to eq(prima[:chiuso])
    expect(workflow.reload.completed_at).to eq(prima[:concluso])
  end

  it "chi non decide su quel progetto non può premerlo" do
    estraneo = create(:account)
    create(:membership, organization:, account: estraneo)

    esito = described_class.call(workflow:, actor: estraneo)

    expect(esito.error.code).to eq("R403-WORKFLOW-001")
    expect(ticket.reload.status).to eq(in_progress)
    expect(probe.reload.closed_at).to be_nil
  end
end
