# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::AlertChannels", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # La validazione webhook risolve il DNS (anti-SSRF): stub a un IP pubblico come nel member spec.
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "senza bearer → 401" do
    get "/cli/v1/alert_channels"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con target umano (URL webhook) e MAI il secret" do
      create(:alerting_channel, organization:, name: "Ops WH",
             config: { "url" => "https://hooks.example.test/ops" }, webhook_secret: "supersegreto")
      other = create(:alerting_channel)

      get "/cli/v1/alert_channels", headers: headers

      data = response.parsed_body["data"]
      expect(data.map { |x| x["id"] }).not_to include(other.id)
      row = data.find { |x| x["name"] == "Ops WH" }
      expect(row["kind"]).to eq("webhook")
      expect(row["target"]).to eq("https://hooks.example.test/ops")
      expect(response.body).not_to include("supersegreto")
    end

    it "create webhook → 201 con url come target" do
      post "/cli/v1/alert_channels",
           params: { name: "Hook", kind: "webhook", webhook_url: "https://example.com/hook" },
           headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "target")).to eq("https://example.com/hook")
    end

    it "create webhook incompleto (URL mancante) → 422 R422-ALERT-001" do
      post "/cli/v1/alert_channels",
           params: { name: "Rotto", kind: "webhook" },
           headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-ALERT-001")
    end

    it "destroy elimina il canale; id di un'altra org → 404" do
      channel = create(:alerting_channel, organization:)
      other = create(:alerting_channel)

      delete "/cli/v1/alert_channels/#{channel.id}", headers: headers
      expect(response).to have_http_status(:no_content)

      delete "/cli/v1/alert_channels/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "le rule accettano threshold e channel_ids dal canale CLI" do
      channel = create(:alerting_channel, organization:)

      post "/cli/v1/alert_rules",
           params: { name: "CPU alta", event_type: "server_cpu", threshold: 90,
                     channel_ids: [ channel.id ] },
           headers: headers

      expect(response).to have_http_status(:created)
      rule = Alerting::Rule.find(response.parsed_body.dig("data", "id"))
      expect(rule.threshold).to eq(90)
      expect(rule.channel_ids).to eq([ channel.id ])
    end

    it "channel_ids di un'altra org vengono scartati (anti-BOLA nel service, no cross-tenant delivery)" do
      mine = create(:alerting_channel, organization:)
      foreign = create(:alerting_channel)

      post "/cli/v1/alert_rules",
           params: { name: "Down", event_type: "server_down",
                     channel_ids: [ mine.id, foreign.id ] },
           headers: headers

      expect(response).to have_http_status(:created)
      rule = Alerting::Rule.find(response.parsed_body.dig("data", "id"))
      expect(rule.channel_ids).to contain_exactly(mine.id)
    end
  end

  context "member senza alerts.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "index e create → 403" do
      get "/cli/v1/alert_channels", headers: headers
      expect(response).to have_http_status(:forbidden)

      expect do
        post "/cli/v1/alert_channels", params: { name: "x", kind: "webhook", webhook_url: "https://x.example" }, headers: headers
      end.not_to change(Alerting::Channel, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
