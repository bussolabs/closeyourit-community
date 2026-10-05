# frozen_string_literal: true

require "rails_helper"

# CYRA-588 — presa in carico atomica dalla coda: un solo giro invece di preflight + claim. Additivo: il
# percorso in due passi resta identico e nessun client va aggiornato per forza.
RSpec.describe "Api::V1::AgentTicketQueueNextClaims (automator)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  let(:params) { { project_key: project.key, host_id: host.id, run_id: "run-42" } }
  let(:path) { "/api/v1/ticket_queue/next_claim" }

  before do
    host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ],
                 runtimes: [ { "name" => "claude", "present" => true } ])
    create(:project_membership, account: host.service_account, project:)
  end

  # La risposta è quella del claim in due passi — lease + attempt_id — con in più il candidato: chi salta
  # il preflight non l'ha mai visto e senza non avrebbe di che lavorare.
  it "consegna in una risposta sola il lease host-first e lo snapshot del candidato" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:created)
    data = response.parsed_body.fetch("data")
    expect(data).to include(
      "ticket" => ticket.code, "host_id" => host.id, "run_id" => "run-42", "agent" => nil,
      "execution_phase" => "triage", "review_depth" => "result"
    )
    expect(data.fetch("attempt_id")).to eq(Agents::Attempt.sole.id)
    # CYRA-921: the machine learns with the work which engine reviews it.
    expect(data.fetch("review_mode")).to eq("cross")
    expect(data.fetch("work_engine")).to eq("claude")
    expect(data.fetch("candidate")).to include("code" => ticket.code, "id" => ticket.id)
    expect(data.dig("candidate", "workflow")).to include("execution_phase" => "triage")
    expect(Agents::Lease.sole).to have_attributes(ticket_id: ticket.id, authoritative_ttl_seconds: 3600)
  end

  # CYRA-921
  it "records the work under the engine the machine was told to use" do
    host.update!(work_engine: "codex", runtimes: [ { "name" => "codex", "present" => true } ])
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "work_engine")).to eq("codex")
    expect(Agents::Attempt.sole.runtime).to eq("codex")
  end

  it "risponde «niente lavoro» quando la coda è vuota" do
    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq({ "data" => nil })
    expect(Agents::Lease).not_to exist
  end

  it "non consegna lo stesso ticket a due postazioni" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-2", platform: "linux", arch: "amd64"
    ).value
    other_host = other.fetch(:host)
    other_host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ],
                       runtimes: [ { "name" => "claude", "present" => true } ])
    create(:project_membership, account: other_host.service_account, project:)

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    post path, params: params.merge(host_id: other_host.id, run_id: "run-43"),
         headers: { "Authorization" => "Bearer #{other.fetch(:secret)}" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq({ "data" => nil })
    expect(Agents::Lease.where(ticket:).count).to eq(1)
  end

  it "rifiuta un bearer mancante o non valido" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    post path, params:, headers: { "Authorization" => "Bearer cyi_ah_inesistente" }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-AGENT-001")
    expect(Agents::Lease).not_to exist
  end

  it "rifiuta un host_id diverso dall'identità del bearer" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    other_host = create(:agent_host, organization:)

    post path, params: params.merge(host_id: other_host.id), headers:, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-LEASE-001")
    expect(Agents::Lease).not_to exist
  end

  it "non rivela un progetto fuori dallo scope dell'host" do
    other_project = create(:project, organization:, key: "OTHR")
    create(:github_repository, project: other_project, installation: repository.installation)
    create(:ticket, :agent_workable, organization:, project: other_project, with_agent_workflow: true)

    post path, params: params.merge(project_key: other_project.key), headers:, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-AGENT-002")
    expect(Agents::Lease).not_to exist
  end

  it "riporta il tetto dei limiti con lo stesso codice del percorso in due passi" do
    create(:agent_limit_policy, organization:, max_parallel: 0)
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include(
      "code" => "R409-QUEUE-002", "details" => { "reason" => "max_parallel" }
    )
    expect(Agents::Lease).not_to exist
  end

  # Scenario 4 del ticket: l'aggiunta è additiva. La sequenza di oggi — preflight firmato, poi claim —
  # continua a funzionare accanto al percorso nuovo, sullo stesso progetto e con lo stesso host.
  it "lascia intatto il percorso in due passi" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    get "/api/v1/ticket_queue", params: { project_key: project.key }, headers: headers
    expect(response).to have_http_status(:ok)
    candidate = response.parsed_body.fetch("data")

    post "/api/v1/ticket_queue/claims",
         params: { selection_token: candidate.fetch("selection_token"), host_id: host.id,
                   run_id: "two-step", ttl_seconds: 3600 },
         headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "ticket")).to eq(candidate.fetch("code"))
    expect(Agents::Lease.sole.run_id).to eq("two-step")
  end
end
