# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Servers", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  # Progetto uptime-capable (piattaforma web/server): il link host↔env esiste solo su questi.
  let(:project) do
    create(:project, organization:).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization:))
    end
  end
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:host) { create(:server_host, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def servers_path(proj = project)
    "/cli/v1/projects/#{proj.id}/servers"
  end

  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }
  end

  it "senza bearer → 401" do
    post servers_path, params: { host_id: host.id, environment_id: environment.id }
    expect(response).to have_http_status(:unauthorized)
  end

  describe "POST create (collega, gate uptime.manage)" do
    it "owner collega host↔environment → 201" do
      expect do
        post servers_path, headers: headers, params: { host_id: host.id, environment_id: environment.id }
      end.to change(Connections::EnvironmentHost, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["host_id"]).to eq(host.id)
      expect(data["environment_id"]).to eq(environment.id)
      expect(Connections::EnvironmentHost.find(data["id"]).created_by).to eq(account)
    end

    it "host inesistente → 422 R422-SERVER-006 (nessun link)" do
      expect do
        post servers_path, headers: headers,
                           params: { host_id: "00000000-0000-0000-0000-000000000000", environment_id: environment.id }
      end.not_to change(Connections::EnvironmentHost, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SERVER-006")
    end

    it "host di un'altra org → 422 (anti-BOLA, non collegabile)" do
      foreign_host = create(:server_host)

      post servers_path, headers: headers, params: { host_id: foreign_host.id, environment_id: environment.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SERVER-006")
    end

    it "environment non dichiarato dal progetto → 422" do
      undeclared = create(:environment, organization:)

      post servers_path, headers: headers, params: { host_id: host.id, environment_id: undeclared.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SERVER-006")
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)

      post servers_path(other), headers: headers, params: { host_id: host.id, environment_id: environment.id }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza uptime.manage → 403" do
      post servers_path, headers: member_headers, params: { host_id: host.id, environment_id: environment.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "DELETE destroy (scollega)" do
    it "owner scollega → 204 e link rimosso" do
      link = Servers::Links::Attach.call(project:, environment:, host:, actor: account).value

      delete "#{servers_path}/#{link.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Connections::EnvironmentHost.exists?(link.id)).to be(false)
    end

    it "link inesistente (o di altro progetto) → 404 (anti-IDOR)" do
      delete "#{servers_path}/00000000-0000-0000-0000-000000000000", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
