# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Agents::AttemptResults", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  let(:attempt) do
    create(:agent_attempt, organization:, workflow:, host:, service_account: host.service_account,
                           skill_key: "/closeyourit-triage",
                           external_run_id: "run-42", phase: "triage", runtime: "claude")
  end
  let!(:lease) do
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-42",
                         execution_phase: "triage", profile_digest: Agents::PhaseProfile.for("triage").digest,
                         expires_at: 5.minutes.from_now)
  end
  let(:payload) do
    {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, category: "backend", capabilities: [ "backend" ], risk: "low",
                requires_human_approval: false, reasons: [ "Realizzabile" ], state: "workable" },
      review: { status: "accepted", summary: "Conforme", depth: "result" }
    }
  end
  let(:path) { api_v1_agent_attempt_result_path(attempt) }

  before do
    host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ],
                 runtimes: [ { "name" => "claude", "present" => true } ])
    # B.5 — scope per-host: la consegna passa da Agents::Hosts::Eligibility, che ora richiede che il
    # service account dell'host veda il progetto; la registrazione lo conia senza progetti, lo abilitiamo qui.
    create(:project_membership, account: host.service_account, project:)
    workflow.update!(triage_started_at: Time.current, ticket_snapshot_digest: "snapshot")
  end

  it "consegna il risultato revisionato e rende idempotente lo stesso payload" do
    expect do
      put path, params: payload, headers:, as: :json
    end.to change { workflow.reload.triaged_at }.from(nil)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("approved")

    expect do
      put path, params: payload, headers:, as: :json
    end.not_to change { attempt.reload.updated_at }
    expect(response).to have_http_status(:ok)
  end

  it "salva costo e modello dichiarati dall'host fuori dal result (CYRA-872)" do
    put path, params: payload.merge(cost_usd: 0.4321, model: "claude-opus-5-5"), headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(attempt.reload).to have_attributes(cost_usd: BigDecimal("0.4321"), model: "claude-opus-5-5")
    expect(attempt.result).not_to have_key("cost_usd")
  end

  it "rifiuta un host differente e non produce effetti" do
    foreign_registration = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "other", platform: "linux", arch: "amd64"
    ).value

    put path, params: payload,
              headers: { "Authorization" => "Bearer #{foreign_registration.fetch(:secret)}" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-ATTEMPT-001")
    expect(workflow.reload.triaged_at).to be_nil
  end
end
