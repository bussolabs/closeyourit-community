# frozen_string_literal: true

require "rails_helper"

# CYRA-872 — costo e modello del tentativo, dichiarati dall'host accanto al result.
RSpec.describe Agents::Attempts::Deliver, "costo del tentativo" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:host_service_account) do
    Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
  end
  let(:host) do
    create(:agent_host, organization:, service_account: host_service_account, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end
  let(:attempt) do
    create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                           skill_key: "/closeyourit-triage", external_run_id: "run-42", phase: "triage",
                           runtime: "claude")
  end
  let(:payload) do
    {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, category: "backend", capabilities: [ "backend" ], risk: "low",
                requires_human_approval: false, reasons: [ "Realizzabile" ], state: "workable" },
      review: { status: "accepted", summary: "Conforme", depth: "result" }
    }
  end

  before do
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-42", execution_phase: "triage",
                         profile_digest: Agents::PhaseProfile.for("triage").digest, expires_at: 5.minutes.from_now)
    workflow.update!(triage_started_at: Time.current, ticket_snapshot_digest: "snapshot")
  end

  def deliver(extra)
    described_class.call(organization:, host:, attempt:, payload: payload.deep_merge(extra))
  end

  it "salva costo e modello su una consegna approvata" do
    expect(deliver(cost_usd: 1.234567, model: "claude-opus-5-5")).to be_ok

    expect(attempt.reload).to have_attributes(status: "approved", cost_usd: BigDecimal("1.234567"),
                                              model: "claude-opus-5-5")
  end

  it "salva il costo anche quando la rilettura boccia: la sessione è stata pagata comunque" do
    result = deliver(cost_usd: 0.5, model: "claude-opus-5-5", review: { status: "changes_requested" })

    expect(result).to be_err
    expect(attempt.reload).to have_attributes(status: "review_failed", cost_usd: BigDecimal("0.5"))
  end

  it "lascia il costo vuoto quando l'host non lo dichiara: mai uno zero inventato" do
    expect(deliver(model: "gpt-6-astra")).to be_ok

    expect(attempt.reload).to have_attributes(cost_usd: nil, model: "gpt-6-astra")
  end

  it "scarta un costo non valido senza perdere la consegna" do
    [ -1, "molto", Float::INFINITY.to_s ].each_with_index do |bad, index|
      attempt.update_columns(delivery_digest: nil, status: Agents::Attempt.statuses[:running], cost_usd: nil)
      workflow.update_columns(triaged_at: nil)
      expect(deliver(cost_usd: bad, model: "m#{index}")).to be_ok, bad.inspect
      expect(attempt.reload.cost_usd).to be_nil, bad.inspect
    end
  end

  it "tronca un modello troppo lungo invece di rifiutare la consegna" do
    expect(deliver(model: "x" * 500)).to be_ok

    expect(attempt.reload.model.length).to eq(100)
  end
end
