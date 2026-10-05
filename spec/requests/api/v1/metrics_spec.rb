# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Metrics (ingest bearer)", type: :request do
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

  def sample(over = {})
    {
      "kind" => "slow_query", "sample_id" => SecureRandom.uuid, "duration_ms" => 120.0,
      "sql" => "SELECT 1", "occurred_at" => Time.current.iso8601
    }.merge(over)
  end

  it "bearer valido + array → 202 { data: { accepted } } e accoda UN SOLO IngestJob per richiesta (CYRA-43)" do
    body = [ sample("sample_id" => "a"), sample("sample_id" => "b") ]
    expect do
      post "/api/v1/projects/#{project.id}/metrics", params: body.to_json, headers: headers
    end.to have_enqueued_job(Metrics::IngestJob).once

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(2)
  end

  it "end-to-end: il singolo job batcha l'intero array (group + N sample)" do
    body = [ sample("sample_id" => "a"), sample("sample_id" => "b"), sample("sample_id" => "c") ]
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/metrics", params: body.to_json, headers: headers
    end
    expect(project.metric_groups.count).to eq(1)
    expect(project.metric_groups.sole.samples_count).to eq(3)
    expect(project.metric_samples.count).to eq(3)
  end

  it "accetta anche un singolo oggetto" do
    expect do
      post "/api/v1/projects/#{project.id}/metrics", params: sample.to_json, headers: headers
    end.to have_enqueued_job(Metrics::IngestJob).once

    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
  end

  it "end-to-end: il job crea group + sample" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/metrics", params: [ sample ].to_json, headers: headers
    end
    expect(project.metric_groups.count).to eq(1)
    expect(project.metric_samples.count).to eq(1)
  end

  it "senza bearer → 401" do
    post "/api/v1/projects/#{project.id}/metrics", params: [ sample ].to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "BOLA: project_id del path ≠ progetto del token → 404" do
    other = create(:project, organization:)
    post "/api/v1/projects/#{other.id}/metrics", params: [ sample ].to_json, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "body malformato → 422 R422-METRIC-001" do
    post "/api/v1/projects/#{project.id}/metrics", params: "{nope", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-METRIC-001")
  end

  it "end-to-end: un verdetto performance_issue (n_plus_one) crea group + sample con trace_id" do
    perf = {
      "kind" => "performance_issue", "subtype" => "n_plus_one", "sample_id" => SecureRandom.uuid,
      "duration_ms" => 320.0, "occurred_at" => Time.current.iso8601, "trace_id" => "req-xyz",
      "sql" => "SELECT * FROM orders WHERE user_id = 7", "source" => "app/models/user.rb:10", "query_count" => 50
    }
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/metrics", params: [ perf ].to_json, headers: headers
    end
    expect(response).to have_http_status(:accepted)
    group = project.metric_groups.first
    expect(group.kind).to eq("performance_issue")
    expect(group.subtype).to eq("n_plus_one")
    expect(project.metric_samples.first.trace_id).to eq("req-xyz")
  end

  # CYRA-194: ParamsWrapper wrappava il body JSON sotto la chiave singolare del controller (`metric`)
  # e faceva merge! in request.request_parameters — cioè proprio ciò che l'ingest persiste. Ogni
  # campione inviato SINGOLARMENTE portava così una copia integrale di sé stesso, mai letta da
  # nessuno: ~51% del payload in produzione. Il batch ne era immune (la copia cade fuori da `_json`).
  it "ingest singolo: il payload salvato non contiene una copia di sé stesso (CYRA-194)" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/metrics", params: sample.to_json, headers: headers
    end

    payload = project.metric_samples.sole.payload
    expect(payload).not_to have_key("metric")
    expect(payload["sql"]).to eq("SELECT <n>") # templatizzato da Normalize, come sempre
  end

  it "batch oltre il cap → 413 R413-METRIC-004 senza accodare nulla" do
    body = Array.new(Metrics::Constants::MAX_BATCH + 1) { sample }
    expect do
      post "/api/v1/projects/#{project.id}/metrics", params: body.to_json, headers: headers
    end.not_to have_enqueued_job(Metrics::IngestJob)
    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("R413-METRIC-004")
  end

  # CYRA-112: cap byte del batch, distinto dal cap sul NUMERO di campioni (R413-METRIC-004): un
  # batch sotto le 1000 righe ma con payload sproporzionalmente enorme sfuggiva a ogni limite.
  # Il confine si testa variando il limite a body fisso, così content_length è esattamente noto:
  # X-1 (sotto → accettato), X (uguale → accettato, il gate è `>`), X+1 (sopra → rifiutato).
  describe "cap byte del batch (CYRA-112)" do
    let(:body) { [ sample ].to_json }

    it "sotto il limite (X-1) → 202" do
      stub_const("Metrics::Constants::MAX_BYTES", body.bytesize + 1)
      post "/api/v1/projects/#{project.id}/metrics", params: body, headers: headers
      expect(response).to have_http_status(:accepted)
    end

    it "esattamente al limite (X) → 202" do
      stub_const("Metrics::Constants::MAX_BYTES", body.bytesize)
      post "/api/v1/projects/#{project.id}/metrics", params: body, headers: headers
      expect(response).to have_http_status(:accepted)
    end

    it "oltre il limite (X+1) → 413 R413-METRIC-006 senza accodare nulla" do
      stub_const("Metrics::Constants::MAX_BYTES", body.bytesize - 1)
      expect do
        post "/api/v1/projects/#{project.id}/metrics", params: body, headers: headers
      end.not_to have_enqueued_job(Metrics::IngestJob)
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-METRIC-006")
    end

    # Il cap deve precedere auth E parse: senza bearer né X-Sentry-Auth l'autenticazione ingest legge
    # params[:sentry_key], e con ciò parserebbe il body. Un payload enorme e malformato deve dare 413
    # (limite di risorse in testa alla catena), non 422 (parse fallito) né 401 (auth fallita).
    it "oltre il limite, senza credenziale e malformato → 413 (precede auth e parse)" do
      stub_const("Metrics::Constants::MAX_BYTES", 10)
      post "/api/v1/projects/#{project.id}/metrics",
           params: "[ malformato e ben oltre i dieci byte", headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-METRIC-006")
    end
  end
end
