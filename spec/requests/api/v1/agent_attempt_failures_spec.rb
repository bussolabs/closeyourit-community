# frozen_string_literal: true

require "rails_helper"

# CYRA-282: l'automator ora ha un canale per dire "questa lavorazione è fallita, col motivo". Prima poteva
# solo rilasciare il lease e riclaimare, quindi un guasto era invisibile. Qui l'host autenticato riporta il
# fallimento del proprio tentativo e il server lo marca `failed`.
RSpec.describe "Api::V1::Agents::AttemptFailures", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
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
  let(:path) { api_v1_agent_attempt_failure_path(attempt) }

  before { workflow.update!(triage_started_at: Time.current) }

  it "marca il tentativo fallito col motivo e riporta il ticket in coda" do
    expect do
      post path, params: { reason: "Sessione uccisa dall'OOM killer." }, headers:, as: :json
    end.to change { attempt.reload.status }.from("running").to("failed")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("failed")
    expect(response.parsed_body.dig("data", "failure_reason")).to eq("Sessione uccisa dall'OOM killer.")
    expect(workflow.reload.triage_started_at).to be_nil # fase riaperta: ticket di nuovo in coda
  end

  it "pretende un motivo" do
    post path, params: { reason: "  " }, headers:, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-ATTEMPT-002")
    expect(attempt.reload).to be_status_running
  end

  it "rifiuta un host che non ha eseguito il tentativo" do
    foreign = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "other", platform: "linux", arch: "amd64"
    ).value

    post path, params: { reason: "Non sono io ad averlo eseguito." },
               headers: { "Authorization" => "Bearer #{foreign.fetch(:secret)}" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-ATTEMPT-001")
    expect(attempt.reload).to be_status_running
  end

  it "risponde 404 per un tentativo di un'altra organizzazione" do
    other_attempt = create(:agent_attempt, workflow: create(:agent_workflow, organization: create(:organization)))

    post api_v1_agent_attempt_failure_path(other_attempt), params: { reason: "x" }, headers:, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-ATTEMPT-001")
  end

  it "richiede il token host (cyi_ah_), non basta l'anonimo" do
    post path, params: { reason: "x" }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
