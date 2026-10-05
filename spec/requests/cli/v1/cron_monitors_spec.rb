# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::CronMonitors", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/cron_monitors"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vede tutti i progetti dell'org)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con i cron monitor dei progetti visibili e meta" do
      mine = create(:cron_monitor, project:)
      other = create(:cron_monitor, project: create(:project, organization:))

      get "/cli/v1/cron_monitors", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |m| m["id"] }
      expect(ids).to include(mine.id, other.id)
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "esclude i cron monitor di un'altra org (anti-BOLA)" do
      mine = create(:cron_monitor, project:)
      elsewhere = create(:cron_monitor)

      get "/cli/v1/cron_monitors", headers: headers

      ids = response.parsed_body["data"].map { |m| m["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(elsewhere.id)
    end

    it "filtra per status" do
      ok = create(:cron_monitor, project:, status: :ok)
      missed = create(:cron_monitor, project:, status: :missed)

      get "/cli/v1/cron_monitors", params: { status: "ok" }, headers: headers

      ids = response.parsed_body["data"].map { |m| m["id"] }
      expect(ids).to include(ok.id)
      expect(ids).not_to include(missed.id)
    end

    it "filtra per project_id (dentro lo scope visibile)" do
      mine = create(:cron_monitor, project:)
      other_project = create(:project, organization:)
      elsewhere = create(:cron_monitor, project: other_project)

      get "/cli/v1/cron_monitors", params: { project_id: project.id }, headers: headers

      ids = response.parsed_body["data"].map { |m| m["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(elsewhere.id)
    end

    it "project_id di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:project)
      get "/cli/v1/cron_monitors", params: { project_id: foreign.id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "show → 200 con id, slug e status" do
      monitor = create(:cron_monitor, project:, name: "Nightly", status: :ok)

      get "/cli/v1/cron_monitors/#{monitor.id}", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["id"]).to eq(monitor.id)
      expect(data["status"]).to eq("ok")
    end

    it "show di un cron monitor di un'altra org → 404 (anti-BOLA)" do
      elsewhere = create(:cron_monitor)
      get "/cli/v1/cron_monitors/#{elsewhere.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  it "member senza assegnazioni non vede alcun cron monitor (strict)" do
    create(:membership, account:, organization:, role: :member)
    create(:cron_monitor, project:)

    get "/cli/v1/cron_monitors", headers: headers
    expect(response.parsed_body["data"]).to be_empty
  end
end
