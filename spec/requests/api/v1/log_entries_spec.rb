# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::LogEntries (lettura)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(project:, name: "CI", host: "bugs.example.com", environment:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "index → 200 { data: [...] } con i log del progetto del token" do
    entry = create(:log_entry, project:)
    get "/api/v1/log_entries", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].map { |l| l["id"] }).to include(entry.id)
  end

  it "espone logger e attributes coi nomi semantici" do
    create(:log_entry, project:, logger_name: "system", data: { "k" => "v" })
    get "/api/v1/log_entries", headers: headers
    row = response.parsed_body["data"].first
    expect(row["logger"]).to eq("system")
    expect(row["attributes"]).to eq("k" => "v")
  end

  it "filtra per level" do
    info = create(:log_entry, project:, level: :info)
    err = create(:log_entry, project:, level: :error)
    get "/api/v1/log_entries", params: { level: "error" }, headers: headers
    ids = response.parsed_body["data"].map { |l| l["id"] }
    expect(ids).to include(err.id)
    expect(ids).not_to include(info.id)
  end

  it "filtra per trace_id" do
    matching = create(:log_entry, project:, trace_id: "t-1")
    other = create(:log_entry, project:, trace_id: "t-2")
    get "/api/v1/log_entries", params: { trace_id: "t-1" }, headers: headers
    ids = response.parsed_body["data"].map { |l| l["id"] }
    expect(ids).to include(matching.id)
    expect(ids).not_to include(other.id)
  end

  it "filtra per environment" do
    prod = create(:log_entry, project:, environment: "production")
    stg = create(:log_entry, project:, environment: "staging")
    get "/api/v1/log_entries", params: { environment: "staging" }, headers: headers
    ids = response.parsed_body["data"].map { |l| l["id"] }
    expect(ids).to include(stg.id)
    expect(ids).not_to include(prod.id)
  end

  it "tronca agli ultimi N (API_PAGE_SIZE) anche con molti log" do
    create_list(:log_entry, App::Constants::API_PAGE_SIZE + 5, project:)
    get "/api/v1/log_entries", headers: headers
    expect(response.parsed_body["data"].size).to eq(App::Constants::API_PAGE_SIZE)
  end

  it "BOLA: i log di un altro progetto non compaiono" do
    foreign = create(:log_entry, project: create(:project, organization:))
    get "/api/v1/log_entries", headers: headers
    expect(response.parsed_body["data"].map { |l| l["id"] }).not_to include(foreign.id)
  end

  it "senza bearer → 401" do
    get "/api/v1/log_entries", headers: {}
    expect(response).to have_http_status(:unauthorized)
  end
end
