# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe "Ingest contract v1", type: :request do
  CONTRACT_ROOT = Rails.root.join("contracts/ingest")
  CONTRACT = CONTRACT_ROOT.join("v1")

  let(:organization) { create(:organization) }
  let(:project) do
    create(:project, organization:, analytics_enabled: true, session_replay_enabled: true)
  end
  let(:environment) { create(:environment, organization:).tap { |item| project.environments << item } }
  let(:issued) do
    Projects::Tokens::Issue.call(
      project:, name: "Contract", host: "bugs.example.com", environment:
    ).value
  end
  let(:headers) do
    {
      "Authorization" => "Bearer #{issued[:secret]}",
      "CONTENT_TYPE" => "application/json",
      "HTTP_USER_AGENT" => "Mozilla/5.0 Chrome/126.0.0.0"
    }
  end

  def contract_json(relative)
    JSON.parse(CONTRACT.join(relative).read)
  end

  it "corrisponde allo snapshot canonico bloccato e a tutti i checksum" do
    lock = JSON.parse(CONTRACT_ROOT.join("LOCK.json").read)
    sums = CONTRACT.join("SHA256SUMS").read
    expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

    sums.each_line do |line|
      expected, relative = line.strip.split("  ./", 2)
      expect(Digest::SHA256.file(CONTRACT.join(relative)).hexdigest).to eq(expected), relative
    end
  end

  it "accetta le golden fixture di ogni canale bearer" do
    fixtures = {
      "events" => "fixtures/valid/events/exception-python.json",
      "logs" => "fixtures/valid/logs/single-python.json",
      "metrics" => "fixtures/valid/metrics/slow-query.json",
      "pageviews" => "fixtures/valid/pageviews/single-browser.json",
      "replays" => "fixtures/valid/replays/single-browser.json"
    }

    allow_n_plus_one do
      aggregate_failures do
        fixtures.each do |channel, relative|
          post "/api/v1/projects/#{project.id}/#{channel}",
               params: contract_json(relative).to_json, headers: headers
          expect(response).to have_http_status(:accepted), channel
        end
      end
    end
  end

  it "applica la matrice bearer: 401 senza credenziale, 403 senza scope e 404 anti-BOLA" do
    payload = contract_json("fixtures/valid/events/message-python.json").to_json
    endpoint = "/api/v1/projects/#{project.id}/events"

    post endpoint, params: payload, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)

    read_only = Projects::Tokens::Issue.call(
      project:, name: "Read only", host: "bugs.example.com",
      environment:, scopes: [ "read" ]
    ).value[:secret]
    post endpoint, params: payload,
         headers: headers.merge("Authorization" => "Bearer #{read_only}")
    expect(response).to have_http_status(:forbidden)

    other = create(:project, organization:)
    post "/api/v1/projects/#{other.id}/events", params: payload, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "accetta la public key sulle route Sentry e su tutti i canali di ingest v1 (CYRA-108)" do
    public_key = issued[:token].public_key
    dsn_headers = {
      "X-Sentry-Auth" => "Sentry sentry_key=#{public_key}, sentry_version=7",
      "CONTENT_TYPE" => "application/json"
    }

    # Route Sentry drop-in (invariate).
    post "/api/#{project.id}/store",
         params: contract_json("fixtures/valid/events/message-python.json").to_json, headers: dsn_headers
    expect(response).to have_http_status(:ok)

    # Canali browser: la public key ora è accettata direttamente sull'API v1, senza gateway.
    post "/api/v1/projects/#{project.id}/pageviews?sentry_key=#{public_key}",
         params: contract_json("fixtures/valid/pageviews/single-browser.json").to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:accepted)

    post "/api/v1/projects/#{project.id}/logs?sentry_key=#{public_key}",
         params: contract_json("fixtures/valid/logs/single-python.json").to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:accepted)
  end

  it "il bundle abilita la public key su ogni canale di ingest v1 e la esclude dalle read (CYRA-108)" do
    cases = contract_json("fixtures/http/auth-cases.json")

    # La DSN public key apre TUTTI i canali di sola scrittura dell'API v1.
    v1_public_ingest = cases.select do |item|
      item["credential"] == "public_dsn" && item["endpoint"].start_with?("/api/v1/projects/")
    end
    expect(v1_public_ingest.pluck("channel")).to contain_exactly("events", "logs", "metrics", "pageviews", "replays")
    expect(v1_public_ingest).to all(include("status" => 202))

    # ...ma NON apre alcuna API di lettura: le read con public key restano rifiutate (401).
    public_reads = cases.select { |item| item["credential"] == "public_dsn" && item["status"] == 401 }
    expect(public_reads).not_to be_empty
    expect(public_reads.pluck("endpoint")).to all(start_with("/api/v1/"))

    # Il gateway applicativo non è più parte del contratto di auth: la public key è diretta.
    expect(cases.pluck("credential")).not_to include("trusted_gateway")
  end
end
