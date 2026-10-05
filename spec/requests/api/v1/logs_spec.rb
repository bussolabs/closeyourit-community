# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Logs (ingest bearer)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "CI", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" } }

  def log(over = {})
    { "event_id" => SecureRandom.uuid, "level" => "info", "message" => "hello",
      "timestamp" => Time.current.iso8601 }.merge(over)
  end

  it "bearer valido + array → 202 { data: { accepted } } e un solo IngestJob batch" do
    body = [ log, log, log ]
    expect do
      post "/api/v1/projects/#{project.id}/logs", params: body.to_json, headers: headers
    end.to have_enqueued_job(Logs::IngestJob).once

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(3)
  end

  it "accetta anche un singolo oggetto" do
    expect do
      post "/api/v1/projects/#{project.id}/logs", params: log.to_json, headers: headers
    end.to have_enqueued_job(Logs::IngestJob).once

    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
  end

  it "end-to-end: il job crea le voci di log" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/logs", params: [ log, log ].to_json, headers: headers
    end
    expect(project.logs_entries.count).to eq(2)
  end

  # CYRA-214 / Scenario 2: la sanitizzazione PII è server-side (gira nel job d'ingest, non nel client),
  # quindi vale per QUALSIASI mittente — anche un POST grezzo da riga di comando senza alcun SDK. Qui
  # l'email arriva in chiaro nel payload e viene persistita come [FILTERED], indipendente dal mittente.
  it "ingest grezzo senza SDK: i dati personali negli attributes sono nascosti a valle (Scenario 2)" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/logs",
           params: log("attributes" => { "email" => "raw@sender.com", "area" => "signup" }).to_json,
           headers: headers
    end
    entry = project.logs_entries.last
    expect(entry.data["email"]).to eq("[FILTERED]")
    expect(entry.data["area"]).to eq("signup")
  end

  it "senza bearer → 401" do
    post "/api/v1/projects/#{project.id}/logs", params: [ log ].to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "BOLA: project_id del path ≠ progetto del token → 404 con envelope" do
    other = create(:project, organization:)
    post "/api/v1/projects/#{other.id}/logs", params: [ log ].to_json, headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-LOG-001")
  end

  it "batch oltre il limite → 413 R413-LOG-002" do
    body = Array.new(Logs::Constants::MAX_BATCH + 1) { log }
    post "/api/v1/projects/#{project.id}/logs", params: body.to_json, headers: headers
    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("R413-LOG-002")
  end

  it "body malformato → 422 R422-LOG-001" do
    post "/api/v1/projects/#{project.id}/logs", params: "{nope", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-LOG-001")
  end

  describe "B4: batch interamente non valido" do
    it "tutti i message vuoti/blank → 422 R422-LOG-004, nessun IngestJob" do
      body = [ log("message" => ""), log("message" => "   ") ]
      expect do
        post "/api/v1/projects/#{project.id}/logs", params: body.to_json, headers: headers
      end.not_to have_enqueued_job(Logs::IngestJob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-LOG-004")
    end

    it "batch misto (1 valido + 1 vuoto) → 202 { accepted: 1 } e accoda il job" do
      body = [ log, log("message" => "") ]
      expect do
        post "/api/v1/projects/#{project.id}/logs", params: body.to_json, headers: headers
      end.to have_enqueued_job(Logs::IngestJob).once

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    end

    it "singolo valido → 202 { accepted: 1 }" do
      post "/api/v1/projects/#{project.id}/logs", params: log.to_json, headers: headers
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    end
  end

  # CYRA-58: il pre-check sincrono che conta gli item accettabili NON deve rieseguire la Normalize
  # completa (deep_clean dell'intero payload + scrub ricorsivo degli attributes) di ogni item nel
  # thread web — quel lavoro pesante lo rifà già il job. Prima del fix ogni batch veniva normalizzato
  # due volte (nel controller e nel job); ora il controller fa solo un check di shape del message.
  describe "CYRA-58: pre-check leggero (niente doppia Normalize)" do
    it "conta gli accettabili senza invocare Normalize completa nel thread web" do
      body = [ log("attributes" => { "deep" => { "token" => "s", "nested" => { "k" => "v" } } }), log, log ]
      expect(Logs::Ingest::Normalize).not_to receive(:call)

      expect do
        post "/api/v1/projects/#{project.id}/logs", params: body.to_json, headers: headers
      end.to have_enqueued_job(Logs::IngestJob).once

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "accepted")).to eq(3)
    end

    it "il conteggio resta esatto anche con item da scartare (message blank)" do
      body = [ log, log("message" => ""), log("message" => "   ") ]
      expect(Logs::Ingest::Normalize).not_to receive(:call)

      post "/api/v1/projects/#{project.id}/logs", params: body.to_json, headers: headers
      expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    end
  end
end
