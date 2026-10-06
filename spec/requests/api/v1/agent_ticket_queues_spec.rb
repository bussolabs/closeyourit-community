# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Agents::TicketQueues (automator)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-automator", default_branch: "main")
  end
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  # Host-first (CYAU-84): coda appiattita, senza agent_id nell'URL.
  let(:path) { "/api/v1/ticket_queue" }

  before do
    host.update!(
      last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ], automator_version: "0.39.0",
      runtimes: [ { "name" => "claude", "present" => true } ]
    )
    # B.5 — scope per-host: la registrazione conia il service account dell'host senza progetti (fail-closed);
    # la coda glielo assegna solo se quel SA vede il progetto, quindi qui gli concediamo la visibilità.
    create(:project_membership, account: host.service_account, project:)
  end

  it "risponde 401 senza token host" do
    get path, params: { project_key: project.key }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-AGENT-001")
  end

  it "risponde con data null quando non esiste un candidato" do
    get path, params: { project_key: project.key }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => nil)
  end

  it "restituisce dettaglio, metadati e repository attestati dal server" do
    status = create(:ticket_status, :in_progress, organization:, code: "working", label: "Working")
    priority = create(:ticket_priority, organization:, code: "high", label: "High", position: 10)
    milestone = create(:milestone, project:, label: "Beta")
    platform = create(:platform, organization:, code: "web", label: "Web")
    project.platforms << platform
    ticket = create(:ticket, :agent_workable, :plain_bug, :with_conditions, organization:, project:, status:, priority:, milestone:,
                                                               technical_analysis: "Analisi tecnica", with_agent_workflow: true)
    ticket.platforms << platform
    comment = create(:ticket_comment, organization:, ticket:, body: "Contesto del reviewer")

    get path, params: { project_key: project.key }, headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include(
      "id" => ticket.id,
      "code" => ticket.code,
      "title" => ticket.title,
      "description" => ticket.description,
      "technical_analysis" => "Analisi tecnica",
      "kind" => "bug",
      "estimated_cost" => nil,
      "selection_token" => be_a(String)
    )
    selection = Agents::TicketQueues::Selection.verify(data.fetch("selection_token"))
    expect(selection).to include(
      organization_id: organization.id, host_id: host.id, execution_phase: "triage",
      profile_digest: Agents::PhaseProfile.for("triage").digest, project_id: project.id, ticket_id: ticket.id,
      estimated_cost: nil
    )
    expect(selection).not_to have_key(:agent_id)
    expect(data.fetch("project")).to eq(
      "id" => project.id, "key" => project.key, "repo" => repository.full_name,
      "default_branch" => repository.default_branch
    )
    expect(data.fetch("status")).to eq(
      "id" => status.id, "code" => "working", "label" => "Working", "category" => "in_progress"
    )
    expect(data.fetch("priority")).to eq(
      "id" => priority.id, "code" => "high", "label" => "High"
    )
    expect(data.fetch("milestone")).to include("id" => milestone.id, "label" => "Beta")
    expect(data.fetch("platforms")).to eq([ { "id" => platform.id, "code" => "web", "label" => "Web" } ])
    expect(data.fetch("conditions")).not_to be_empty
    expect(data.fetch("comments")).to contain_exactly(
      include("id" => comment.id, "body" => "Contesto del reviewer",
              "author" => { "id" => comment.author_id, "name" => comment.author.name })
    )
  end

  it "non crea un claim durante il polling" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect do
      get path, params: { project_key: project.key }, headers: headers
    end.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "id")).to eq(ticket.id)
  end

  it "emette una selezione consumabile soltanto dal claim queue-specific" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    get path, params: { project_key: project.key }, headers: headers
    token = response.parsed_body.dig("data", "selection_token")

    post "/api/v1/ticket_queue/claims",
         params: {
           selection_token: token,
           host_id: host.id,
           run_id: "run-from-preflight",
           # Host-first (CYAU-91): TTL autoritativo dal PhaseProfile (fase triage → 3600), non dal timeout agente.
           ttl_seconds: 3600
         },
         headers:, as: :json

    expect(response).to have_http_status(:created)
    # Host-first (CYAU-84): lease host-first puro, nessuno slug agent (agent = null).
    expect(response.parsed_body.fetch("data")).to include(
      "ticket" => ticket.code, "agent" => nil, "run_id" => "run-from-preflight", "execution_phase" => "triage"
    )
  end

  it "risponde 403 per un host non certificato (gate host-side)" do
    host.update!(certified_at: nil)
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    get path, params: { project_key: project.key }, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-AGENT-006")
  end

  it "risponde 403 per un host storico non Linux prima di leggere la coda" do
    host.update_column(:platform, "darwin")
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect { get path, params: { project_key: project.key }, headers: headers }
      .not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-AGENT-007")
  end

  it "risponde 404 per un progetto non assegnato o di un altro tenant" do
    unassigned = create(:project, organization:, key: "OTHR")
    create(:github_repository, project: unassigned, installation: repository.installation)

    get path, params: { project_key: unassigned.key }, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-AGENT-002")

    foreign = create(:project, key: "FRGN")
    create(:github_repository, project: foreign)
    get path, params: { project_key: foreign.key }, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-AGENT-002")
  end

  it "risponde 404 per un progetto senza repository" do
    repository.destroy!

    get path, params: { project_key: project.key }, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-AGENT-002")
  end

  it "rifiuta il token organization riservato al bootstrap" do
    issued = Agents::Tokens::Issue.call(organization:, name: "bootstrap").value

    get path, params: { project_key: project.key }, headers: { "Authorization" => "Bearer #{issued[:secret]}" }

    expect(response).to have_http_status(:unauthorized)
  end
end
