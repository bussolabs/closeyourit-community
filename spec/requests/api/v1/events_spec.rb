# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Events (ingest bearer custom)", type: :request do
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

  def event = { "event_id" => "feedface", "level" => "error", "message" => "ci signal" }

  it "bearer valido + project del token → 202 { data: { id } } e accoda l'IngestJob" do
    expect do
      post "/api/v1/projects/#{project.id}/events", params: event.to_json, headers: headers
    end.to have_enqueued_job(Errors::IngestJob)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "id")).to eq("feedface")
  end

  it "end-to-end: il job crea gruppo + evento" do
    # except: l'embed del gruppo esce verso un servizio che qui non è configurato e dal CYRA-713 un
    # job che fallisce non viene più ritentato in silenzio: qui si prova l'ingest, non l'embedding.
    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
      post "/api/v1/projects/#{project.id}/events", params: event.to_json, headers: headers
    end
    expect(project.error_groups.count).to eq(1)
    expect(project.error_events.count).to eq(1)
  end

  # CYRA-194: gemello del caso metriche — qui la chiave duplicata era `event`, ed essendo gli eventi
  # sempre inviati uno per volta la copia colpiva il 100% delle righe (la più pesante del payload,
  # sopra `exception`).
  it "il payload salvato non contiene una copia di sé stesso (CYRA-194)" do
    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
      post "/api/v1/projects/#{project.id}/events", params: event.to_json, headers: headers
    end

    payload = project.error_events.sole.payload
    expect(payload).not_to have_key("event")
    expect(payload["message"]).to eq("ci signal")
  end

  it "end-to-end: payload arricchito conservato (request/user/tags/breadcrumbs) senza PII" do
    enriched = {
      "event_id" => "cafed00d",
      "level" => "error",
      "exception" => { "values" => [ {
        "type" => "RuntimeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "function" => "call", "module" => "App", "in_app" => true } ] }
      } ] },
      "user" => { "id" => "9", "email" => "a@b.com" },
      "request" => { "method" => "GET", "url" => "https://x/orders/9",
                     "headers" => { "Authorization" => "Bearer s", "Accept" => "json" } },
      "tags" => { "area" => "checkout" },
      "breadcrumbs" => { "values" => [ { "category" => "query", "message" => "SELECT ?",
                                         "data" => { "name" => "User Load", "password" => "x" } } ] }
    }

    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
      post "/api/v1/projects/#{project.id}/events", params: enriched.to_json, headers: headers
    end

    expect(project.error_groups.count).to eq(1)
    payload = project.error_events.sole.payload
    expect(payload.dig("request", "method")).to eq("GET")
    # gli header sensibili sono redatti (chiave preservata, valore [FILTERED]) invece che rimossi.
    expect(payload.dig("request", "headers")).to eq("Accept" => "json", "Authorization" => "[FILTERED]")
    expect(payload["user"]).to eq("id" => "9")
    expect(payload.dig("breadcrumbs", "values").first["data"]).to eq("name" => "User Load", "password" => "[FILTERED]")
    expect(project.error_events.sole.context["tags"]).to eq("area" => "checkout")
  end

  it "B1: trace_id top-level conservato e indicizzato sull'evento" do
    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
      post "/api/v1/projects/#{project.id}/events",
           params: event.merge("trace_id" => "trace-deadbeef").to_json, headers: headers
    end
    stored = project.error_events.sole
    expect(stored.trace_id).to eq("trace-deadbeef")
    expect(Errors::Event.where(trace_id: "trace-deadbeef")).to include(stored)
  end

  it "B1: evento senza trace_id ingerisce comunque (nil)" do
    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
      post "/api/v1/projects/#{project.id}/events", params: event.to_json, headers: headers
    end
    expect(project.error_events.sole.trace_id).to be_nil
  end

  it "B3: ri-scruba tags/extra/contexts difensivamente (payload + context), runtime intatto" do
    enriched = event.merge(
      "tags" => { "area" => "checkout", "api_key" => "sk_live_x" },
      "extra" => { "order_id" => "9", "password" => "p" },
      "contexts" => { "runtime" => { "name" => "ruby", "version" => "4.0" }, "auth" => { "token" => "t" } }
    )
    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
      post "/api/v1/projects/#{project.id}/events", params: enriched.to_json, headers: headers
    end
    stored = project.error_events.sole
    expect(stored.context["tags"]).to eq("area" => "checkout", "api_key" => "[FILTERED]")
    expect(stored.context["extra"]).to eq("order_id" => "9", "password" => "[FILTERED]")
    expect(stored.context.dig("contexts", "runtime")).to eq("name" => "ruby", "version" => "4.0")
    expect(stored.payload.dig("tags", "api_key")).to eq("[FILTERED]")
    expect(stored.payload.dig("contexts", "auth", "token")).to eq("[FILTERED]")
  end

  it "CYRA-211: il corpo dell'evento non entra negli argomenti del job in coda (solo un riferimento)" do
    post "/api/v1/projects/#{project.id}/events", params: event.to_json, headers: headers

    expect(enqueued_jobs.size).to eq(1)
    expect(enqueued_jobs.first.to_json).not_to include("ci signal")
    expect(Errors::IngestPayload.sole.payload["message"]).to eq("ci signal")
  end

  it "senza bearer → 401" do
    post "/api/v1/projects/#{project.id}/events", params: event.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "BOLA: project_id del path ≠ progetto del token → 404" do
    other = create(:project, organization:)
    post "/api/v1/projects/#{other.id}/events", params: event.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "body malformato → 422 R422-INGEST-001" do
    post "/api/v1/projects/#{project.id}/events", params: "{nope", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-INGEST-001")
  end

  # CYRA-112: cap byte dedicato al singolo evento bearer (prima assente: solo il limite di Rack).
  # Il confine si testa variando il limite a body fisso, così content_length è esattamente noto:
  # X-1 (sotto → accettato), X (uguale → accettato, il gate è `>`), X+1 (sopra → rifiutato).
  describe "cap byte del singolo evento (CYRA-112)" do
    let(:body) { event.to_json }

    it "sotto il limite (X-1) → 202" do
      stub_const("Errors::Constants::EVENTS_MAX_BYTES", body.bytesize + 1)
      post "/api/v1/projects/#{project.id}/events", params: body, headers: headers
      expect(response).to have_http_status(:accepted)
    end

    it "esattamente al limite (X) → 202" do
      stub_const("Errors::Constants::EVENTS_MAX_BYTES", body.bytesize)
      post "/api/v1/projects/#{project.id}/events", params: body, headers: headers
      expect(response).to have_http_status(:accepted)
    end

    it "oltre il limite (X+1) → 413 R413-INGEST-002 senza accodare nulla" do
      stub_const("Errors::Constants::EVENTS_MAX_BYTES", body.bytesize - 1)
      expect do
        post "/api/v1/projects/#{project.id}/events", params: body, headers: headers
      end.not_to have_enqueued_job(Errors::IngestJob)
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-002")
    end

    # Il cap deve precedere auth E parse: senza bearer né X-Sentry-Auth l'autenticazione ingest legge
    # params[:sentry_key], e con ciò parserebbe il body. Un payload enorme e malformato deve dare 413
    # (limite di risorse in testa alla catena), non 422 (parse fallito) né 401 (auth fallita).
    it "oltre il limite, senza credenziale e malformato → 413 (precede auth e parse)" do
      stub_const("Errors::Constants::EVENTS_MAX_BYTES", 10)
      post "/api/v1/projects/#{project.id}/events",
           params: "{ malformato e ben oltre i dieci byte", headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-002")
    end
  end
end
