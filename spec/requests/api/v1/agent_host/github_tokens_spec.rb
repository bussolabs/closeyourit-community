# frozen_string_literal: true

require "rails_helper"

# CYRA-1058 — a GitHub token valid one hour for the only repository of the ticket the machine holds.
RSpec.describe "Api::V1::AgentHost::GithubTokens", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "ALEX") }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  let(:path) { "/api/v1/agent_host/github_token" }
  let(:installation) { create(:github_installation, organization:, installation_id: 4242) }
  let(:token_url) { "https://api.github.com/app/installations/4242/access_tokens" }

  before do
    account = create(:account, :service)
    create(:membership, account:, organization:, role: :member)
    create(:project_membership, account:, project:)
    host.update!(service_account: account, certified_at: Time.current)
    create(:github_repository, project:, installation:, full_name: "bussolabs/alex-nuxt")
    allow(Settings::Integrations).to receive(:value).and_call_original
    allow(Settings::Integrations).to receive(:value).with(:gh_app_id).and_return("42")
    allow(Settings::Integrations).to receive(:value).with(:gh_app_private_key)
                                                  .and_return(OpenSSL::PKey::RSA.new(2048).to_pem)
  end

  def hold_lease(phase:, holder: host, expires_at: 30.minutes.from_now)
    create(:agent_lease, :host_first, host: holder, organization:, ticket:, execution_phase: phase,
                                       profile_digest: Agents::PhaseProfile.for(phase).digest, expires_at:)
  end

  def stub_token(permissions)
    stub_request(:post, token_url)
      .with(body: { repositories: [ "alex-nuxt" ], permissions: }.to_json)
      .to_return(status: 201, body: { token: "ghs_scoped", expires_at: "2026-10-08T20:00:00Z" }.to_json)
  end

  it "gives the delivering phase a token that can push and open a pull request on the ticket's repository only" do
    hold_lease(phase: "autopilot")
    req = stub_token(contents: "write", pull_requests: "write", checks: "read", statuses: "read", actions: "read")

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body["data"]).to eq(
      "env" => "GH_TOKEN", "token" => "ghs_scoped", "expires_at" => "2026-10-08T20:00:00Z"
    )
    expect(req).to have_been_requested
  end

  # CYRA-1063 — the closers merge the pull request and push the release tag: read-only stopped them.
  %w[closer_staging closer_production].each do |phase|
    it "gives #{phase} a token that can merge and push a tag" do
      hold_lease(phase:)
      req = stub_token(contents: "write", pull_requests: "write", checks: "read", statuses: "read", actions: "read")

      post path, params: { ticket: ticket.code }, headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(req).to have_been_requested
    end
  end

  it "gives the other phases a read-only token" do
    hold_lease(phase: "triage")
    req = stub_token(contents: "read", checks: "read", statuses: "read", actions: "read")

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(req).to have_been_requested
  end

  it "refuses a host that does not hold the ticket" do
    hold_lease(phase: "autopilot", holder: create(:agent_host, organization:))

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-AGENT-009")
  end

  it "refuses when the lease has expired" do
    hold_lease(phase: "autopilot", expires_at: 1.minute.ago)

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response.parsed_body["error"]["code"]).to eq("R403-AGENT-009")
  end

  it "refuses an uncertified host" do
    hold_lease(phase: "autopilot")
    host.update!(certified_at: nil)

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-AGENT-010")
  end

  it "answers 404 for a ticket of another organization" do
    other = create(:ticket, organization: create(:organization))

    post path, params: { ticket: other.code }, headers:, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-AGENT-007")
  end

  it "answers 404 when the project has no GitHub repository" do
    hold_lease(phase: "autopilot")
    project.github_repository.destroy!

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-AGENT-008")
  end

  it "answers 502 when GitHub refuses to mint the token" do
    hold_lease(phase: "autopilot")
    stub_request(:post, token_url).to_return(status: 422, body: { message: "nope" }.to_json)

    post path, params: { ticket: ticket.code }, headers:, as: :json

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body["error"]["code"]).to eq("R502-GITHUB-001")
  end

  it "refuses a request without a host token" do
    post path, params: { ticket: ticket.code }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
