# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::LogEntries", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  context "owner (vede tutto)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → stream cross-app con meta" do
      a = create(:log_entry, project:)
      b = create(:log_entry, project: create(:project, organization:))
      get "/cli/v1/log_entries", headers: headers
      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to include(a.id, b.id)
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "filtra per project_id (dentro lo scope visibile)" do
      mine = create(:log_entry, project:)
      other_project = create(:project, organization:)
      elsewhere = create(:log_entry, project: other_project)
      get "/cli/v1/log_entries", params: { project_id: project.id }, headers: headers
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(elsewhere.id)
    end

    it "filtra per level" do
      err = create(:log_entry, project:, level: :error)
      info = create(:log_entry, project:, level: :info)
      get "/cli/v1/log_entries", params: { level: "error" }, headers: headers
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to include(err.id)
      expect(ids).not_to include(info.id)
    end

    it "filtra per trace_id" do
      match = create(:log_entry, project:, trace_id: "trace-abc")
      other = create(:log_entry, project:, trace_id: "trace-xyz")
      get "/cli/v1/log_entries", params: { trace_id: "trace-abc" }, headers: headers
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to include(match.id)
      expect(ids).not_to include(other.id)
    end

    it "filtra per environment" do
      prod = create(:log_entry, project:, environment: "production")
      stg = create(:log_entry, project:, environment: "staging")
      get "/cli/v1/log_entries", params: { environment: "production" }, headers: headers
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to include(prod.id)
      expect(ids).not_to include(stg.id)
    end

    it "project_id di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:project)
      get "/cli/v1/log_entries", params: { project_id: foreign.id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "show → 200 con il log nello scope visibile" do
      entry = create(:log_entry, project:, message: "boom")

      get "/cli/v1/log_entries/#{entry.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(entry.id)
    end

    it "show di un log di un progetto non visibile (altra org) → 404 (anti-BOLA)" do
      foreign = create(:log_entry, project: create(:project))

      get "/cli/v1/log_entries/#{foreign.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end
  end

  it "member senza assegnazioni non vede alcun log (strict)" do
    create(:membership, account:, organization:, role: :member)
    create(:log_entry, project:)
    get "/cli/v1/log_entries", headers: headers
    expect(response.parsed_body["data"]).to be_empty
  end

  it "senza bearer → 401" do
    get "/cli/v1/log_entries"
    expect(response).to have_http_status(:unauthorized)
  end
end
