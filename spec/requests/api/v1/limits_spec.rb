# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Limits (automator)", type: :request do
  let(:organization) { create(:organization) }
  let(:organization_token) { Agents::Tokens::Issue.call(organization:, name: "automator").value[:secret] }
  let(:organization_headers) { { "Authorization" => "Bearer #{organization_token}" } }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host_headers) { { "Authorization" => "Bearer #{registration[:secret]}" } }
  let(:project) { create(:project, organization:, key: "LIM") }
  let(:github_installation) { create(:github_installation, organization:) }
  let(:repository) do
    create(:github_repository, project:, installation: github_installation, full_name: "bussolabs/limits-reservation")
  end

  # Le prove di contratto usano freeze/travel; il clock PostgreSQL reale è verificato separatamente
  # nella suite concorrente, mentre qui il facade segue intenzionalmente il tempo controllato dal test.
  # Host-first (CYAU-91): Reserve verifica ProjectScope host-only, quindi il service account dell'host
  # (creato cieco da Register) deve vedere il progetto. Il TTL/runtime derivano dalla fase (PhaseProfile).
  before do
    allow(Agents::Limits::Clock).to receive(:current) { Time.current }
    create(:project_membership, account: registration.fetch(:host).service_account, project:)
  end

  describe "GET /api/v1/limits" do
    it "espone una policy permissiva e cacheabile sia al bootstrap sia all'host" do
      get "/api/v1/limits", headers: organization_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include(
        "scope" => "organization", "stop_dispatch" => false, "max_age_seconds" => 60
      )

      get "/api/v1/limits", headers: host_headers
      expect(response).to have_http_status(:ok)
    end

    it "compone in modo restrittivo policy organization, progetto e runtime" do
      repository = create(:github_repository, project:, full_name: "bussolabs/limits")
      create(:agent_limit_policy, organization:, max_parallel: 4, max_daily_runs: 20)
      create(:agent_limit_policy, organization:, project:, max_parallel: 2)
      create(:agent_limit_policy, organization:, project:, runtime: "codex", max_daily_runs: 7,
                                  stop_dispatch: true, max_age_seconds: 15)

      get "/api/v1/limits", params: { repository: repository.full_name, runtime: "codex" }, headers: host_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include(
        "scope" => "repository", "max_parallel" => 2, "max_daily_runs" => 7,
        "stop_dispatch" => true, "max_age_seconds" => 15
      )
    end

    it "non rivela repository di un altro tenant" do
      foreign = create(:github_repository, full_name: "other/private")

      get "/api/v1/limits", params: { repository: foreign.full_name }, headers: host_headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-AGENT-002")
    end
  end
end
