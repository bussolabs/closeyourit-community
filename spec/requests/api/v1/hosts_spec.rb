# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Hosts (automator)", type: :request do
  let(:organization) { create(:organization) }
  # La macchina si auto-registra col token del SUO service account (cyi_u_), creato dall'admin con lo scope
  # deciso (ambienti/progetti). La registrazione lega l'host a quel service account senza crearne uno nuovo
  # né allargarne i permessi.
  let(:service_account) { Accounts::Service::Create.call(organization:, name: "minion-1").value }
  let(:sa_token) { Accounts::ApiTokens::Issue.call(account: service_account, organization:, name: "minion").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{sa_token}" } }
  let(:params) do
    {
      fingerprint: "machine-abc",
      hostname: "workstation-1",
      platform: "linux",
      arch: "arm64",
      automator_version: "1.2.3"
    }
  end

  it "senza token → 401" do
    post "/api/v1/hosts", params: params

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-CLIAUTH-001")
  end

  it "un account UMANO (non service) non può registrare un host → 403 e non crea nulla" do
    human = create(:account)
    create(:membership, account: human, organization:)
    human_token = Accounts::ApiTokens::Issue.call(account: human, organization:, name: "cli").value[:secret]

    expect do
      post "/api/v1/hosts", headers: { "Authorization" => "Bearer #{human_token}" }, params: params
    end.not_to change(Agents::Host, :count)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-AGENT-002")
  end

  it "il service account registra l'host, lo lega a sé e rivela una volta la credenziale host" do
    post "/api/v1/hosts", headers:, params: params

    expect(response).to have_http_status(:created)
    data = response.parsed_body.fetch("data")
    host = Agents::Host.sole
    expect(host.service_account).to eq(service_account)
    expect(data).to include("id" => host.id, "token" => a_string_starting_with("cyi_ah_"))
    expect(data).to include("fingerprint" => "machine-abc", "hostname" => "workstation-1")
    expect(response.body).not_to include("token_digest", "token_prefix")
    expect(Agents::HostToken.sole.token_digest).to eq(Digest::SHA256.hexdigest(data.fetch("token")))
  end

  it "rifiuta macOS con 422 senza creare host o credenziali" do
    expect do
      post "/api/v1/hosts", headers:, params: params.merge(platform: "darwin")
    end.to not_change(Agents::Host, :count).and not_change(Agents::HostToken, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-AGENT-004")
    expect(response.parsed_body.dig("error", "details", "platform")).to eq([ "deve essere linux" ])
  end

  it "è idempotente sull'identità e al retry ruota la credenziale reveal-once" do
    post "/api/v1/hosts", headers:, params: params
    first = response.parsed_body.fetch("data")

    expect do
      post "/api/v1/hosts", headers:, params: params.merge(hostname: "workstation-renamed")
    end.not_to change(Agents::Host, :count)

    expect(response).to have_http_status(:ok)
    second = response.parsed_body.fetch("data")
    expect(second.fetch("id")).to eq(first.fetch("id"))
    expect(second.fetch("token")).not_to eq(first.fetch("token"))
    expect(Agents::HostToken.active.count).to eq(1)
    expect(Agents::Host.sole.service_account).to eq(service_account)
  end

  it "un altro service account non può rilevare un host già legato ad un altro → 409" do
    post "/api/v1/hosts", headers:, params: params
    other = Accounts::Service::Create.call(organization:, name: "minion-2").value
    other_token = Accounts::ApiTokens::Issue.call(account: other, organization:, name: "m2").value[:secret]

    expect do
      post "/api/v1/hosts", headers: { "Authorization" => "Bearer #{other_token}" }, params: params
    end.not_to change(Agents::Host, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-AGENT-003")
    expect(Agents::Host.sole.service_account).to eq(service_account)
  end

  it "lo stesso service account non può registrare un SECONDO host (fingerprint diverso) → 409, mai 500" do
    post "/api/v1/hosts", headers:, params: params
    expect(response).to have_http_status(:created)

    expect do
      post "/api/v1/hosts", headers:, params: params.merge(fingerprint: "machine-2")
    end.not_to change(Agents::Host, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-AGENT-004")
  end

  it "rifiuta payload invalidi senza persistere righe parziali" do
    expect { post "/api/v1/hosts", headers:, params: params.merge(fingerprint: "") }
      .not_to change(Agents::Host, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-AGENT-004")
    expect(Agents::HostToken.count).to eq(0)
  end

  it "non registra di nuovo un host revocato" do
    create(:agent_host, :revoked, organization:, fingerprint: params[:fingerprint])

    post "/api/v1/hosts", headers:, params: params

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-AGENT-001")
    expect(Agents::HostToken.count).to eq(0)
  end

  it "isola lo stesso fingerprint tra organization diverse" do
    post "/api/v1/hosts", headers:, params: params
    other_org = create(:organization)
    other_sa = Accounts::Service::Create.call(organization: other_org, name: "minion-x").value
    other_token = Accounts::ApiTokens::Issue.call(account: other_sa, organization: other_org, name: "x").value[:secret]

    expect do
      post "/api/v1/hosts", headers: { "Authorization" => "Bearer #{other_token}" }, params: params
    end.to change(Agents::Host, :count).by(1)

    expect(Agents::Host.where(fingerprint: "machine-abc").distinct.count(:organization_id)).to eq(2)
  end
end
