# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Leases (automator)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:database_now) { Time.zone.parse("2026-07-13 14:00:00") }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  let(:params) do
    { ticket: ticket.code, host_id: host.id, run_id: "run-42", agent: "triage", ttl_seconds: 60 }
  end

  def lease_path(action = nil, ref: ticket.code)
    [ "/api/v1/leases", ref, action ].compact.join("/")
  end

  before do
    [ host ].each do |agent_host|
      account = agent_host.service_account || create(:account, :service)
      create(:membership, account: account, organization: organization, role: :member) unless account.memberships.exists?(organization_id: organization.id)
      agent_host.update!(service_account: account)
      create(:project_membership, account: account, project: project)
    end
    allow(Agents::Leases::Clock).to receive(:current).and_return(database_now)
  end

  it "richiede un token host e rifiuta il token organization" do
    post "/api/v1/leases", params: params, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-AGENT-001")

    issued = Agents::Tokens::Issue.call(organization:, name: "bootstrap").value
    post "/api/v1/leases", params:, headers: { "Authorization" => "Bearer #{issued[:secret]}" }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "acquisisce con 201 e scadenza server-side nell'envelope" do
    travel_to(database_now + 10.years) do
      post "/api/v1/leases", params: params.merge(expires_at: 10.years.from_now), headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.fetch("data")).to include(
        "ticket" => ticket.code, "host_id" => host.id, "run_id" => "run-42", "agent" => "triage",
        "expires_at" => (database_now + 60.seconds).as_json
      )
      expect(response.body).not_to include("organization_id", "ticket_id")
    end
  end

  it "acquisisce host-first ed espone execution_phase e profile_digest (derivato server-side)" do
    post "/api/v1/leases", params: params.except(:agent).merge(execution_phase: "triage"),
                           headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("data")).to include(
      "execution_phase" => "triage",
      "profile_digest" => Agents::PhaseProfile.for("triage").digest
    )
  end

  it "retry stesso host+run restituisce 200 senza duplicare" do
    post "/api/v1/leases", params: params, headers: headers, as: :json

    expect { post "/api/v1/leases", params: params, headers: headers, as: :json }.not_to change(Agents::Lease, :count)
    expect(response).to have_http_status(:ok)
  end

  it "409 espone holder al client e codice errore" do
    post "/api/v1/leases", params: params, headers: headers, as: :json
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-2", platform: "linux", arch: "amd64"
    ).value
    create(:project_membership, account: other[:host].service_account, project:)

    post "/api/v1/leases",
         params: params.merge(host_id: other[:host].id, run_id: "run-other"),
         headers: { "Authorization" => "Bearer #{other[:secret]}" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("data", "host_id")).to eq(host.id)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-LEASE-001")
  end

  it "rifiuta spoof host_id con 403" do
    post "/api/v1/leases", params: params.merge(host_id: create(:agent_host, organization:).id),
                           headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-LEASE-001")
  end

  it "ticket di un'altra organization resta 404 senza lease (BOLA)" do
    foreign = create(:ticket, organization: create(:organization))
    post "/api/v1/leases", params: params.merge(ticket: foreign.code), headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-LEASE-001")
    expect(Agents::Lease.count).to eq(0)
  end

  it "renew estende dal tempo server e preserva owner" do
    post "/api/v1/leases", params: params, headers: headers, as: :json

    allow(Agents::Leases::Clock).to receive(:current).and_return(database_now + 30.seconds)
    post lease_path("renew"), params: params.except(:agent).merge(ttl_seconds: 120), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include(
      "host_id" => host.id, "run_id" => "run-42", "expires_at" => (database_now + 150.seconds).as_json
    )
  end

  it "renew di un altro owner è 409; scaduto è 404" do
    lease = create(:agent_lease, organization:, ticket:, host:, run_id: "run-42")
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-2", platform: "linux", arch: "amd64"
    ).value
    create(:project_membership, account: other[:host].service_account, project:)

    post lease_path("renew"), params: params.except(:agent).merge(host_id: other[:host].id, run_id: "other"),
                              headers: { "Authorization" => "Bearer #{other[:secret]}" }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("data", "host_id")).to eq(host.id)

    allow(Agents::Leases::Clock).to receive(:current).and_return(lease.expires_at + 1.second)
    post lease_path("renew"), params: params.except(:agent), headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-LEASE-002")
  end

  it "release è 200 per owner e al retry idempotente" do
    post "/api/v1/leases", params: params, headers: headers, as: :json

    post lease_path("release"), params: params.except(:agent, :ttl_seconds), headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "released")).to be(true)

    post lease_path("release"), params: params.except(:agent, :ttl_seconds), headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "released")).to be(true)
  end

  it "acquire ritardato dopo release è 409 senza holder riutilizzabile dal client" do
    post "/api/v1/leases", params: params, headers: headers, as: :json
    post lease_path("release"), params: params.except(:agent, :ttl_seconds), headers: headers, as: :json

    post "/api/v1/leases", params: params, headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).not_to have_key("data")
    expect(response.parsed_body.dig("error", "code")).to eq("R409-LEASE-002")
  end

  it "path e ticket body discordi restituiscono 422" do
    post lease_path("renew"), params: params.except(:agent).merge(ticket: "CYAU-999"),
                              headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-LEASE-001")
    expect(Agents::Lease.count).to eq(0)
  end

  it "input estremi di TTL e identificatori restituiscono 422 senza eccezioni" do
    post "/api/v1/leases",
         params: params.merge(ttl_seconds: Agents::Leases::Operation::MAX_TTL_SECONDS + 1),
         headers:, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    post "/api/v1/leases",
         params: params.merge(run_id: "x" * (Agents::Leases::Operation::MAX_IDENTIFIER_LENGTH + 1)),
         headers:, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-LEASE-001")
    expect(Agents::Lease.count).to eq(0)
  end

  %w[acquire renew release].each do |action|
    it "numero ticket oltre il range restituisce 422 su #{action}" do
      overflow_reference = "CYAU-2147483648"
      overflow_params = params.merge(ticket: overflow_reference)
      path = action == "acquire" ? "/api/v1/leases" : lease_path(action, ref: overflow_reference)
      request_params = action == "acquire" ? overflow_params : overflow_params.except(:agent, :ttl_seconds)

      expect do
        post path, params: request_params, headers:, as: :json
      end.not_to change(Agents::Lease, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-LEASE-001")
    end
  end
end
