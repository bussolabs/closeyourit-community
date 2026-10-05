# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Monitors::Announcements", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) do
    create(:project, organization:).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization:))
    end
  end
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:monitor) { create(:uptime_monitor, project:, environment:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def announcement_path(m = monitor)
    "/cli/v1/projects/#{project.id}/monitors/#{m.id}/announcement"
  end

  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }
  end

  it "senza bearer → 401" do
    get announcement_path
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET show" do
    it "nessun annuncio → 200 con data null" do
      get announcement_path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to be_nil
    end

    it "ritorna l'annuncio corrente" do
      create(:uptime_announcement, monitor:, level: :warning, message: "Degrado in corso")

      get announcement_path, headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["level"]).to eq("warning")
      expect(data["message"]).to eq("Degrado in corso")
    end
  end

  describe "PUT update (upsert)" do
    it "crea l'annuncio → 200 con level/message" do
      put announcement_path, headers: headers, params: { level: "info", message: "Deploy in corso" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("level" => "info", "message" => "Deploy in corso")
      expect(monitor.reload.announcement).to be_present
    end

    it "aggiorna l'annuncio esistente (upsert, un solo record)" do
      create(:uptime_announcement, monitor:, message: "Vecchio")

      expect do
        put announcement_path, headers: headers, params: { message: "Nuovo" }
      end.not_to change(Uptime::Announcement, :count)

      expect(response).to have_http_status(:ok)
      expect(monitor.reload.announcement.message).to eq("Nuovo")
    end

    it "message vuoto → 422 R422-UPTIME-003" do
      put announcement_path, headers: headers, params: { level: "info", message: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-UPTIME-003")
    end

    it "monitor di un'altra org → 404 (anti-BOLA)" do
      other = create(:uptime_monitor)

      put announcement_path(other), headers: headers, params: { message: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza uptime.manage → 403" do
      put announcement_path, headers: member_headers, params: { message: "x" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "DELETE destroy (clear)" do
    it "rimuove l'annuncio → 204" do
      create(:uptime_announcement, monitor:)

      delete announcement_path, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(monitor.reload.announcement).to be_nil
    end
  end
end
