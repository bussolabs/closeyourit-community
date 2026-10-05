# frozen_string_literal: true

require "rails_helper"

# CYRA-538 — la porta da cui entrano le misure di velocità prese dai visitatori veri. Stesso confine
# PII dei pageview: IP e user-agent muoiono nel controller.
RSpec.describe "Api::V1::WebVitals (ingest bearer)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, analytics_enabled: true) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "Browser", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:chrome_ua) do
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " \
      "Version/17.0 Mobile/15E148 Safari/604.1"
  end
  let(:headers) do
    { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json",
      "HTTP_USER_AGENT" => chrome_ua, "REMOTE_ADDR" => "203.0.113.9" }
  end

  def misura(over = {})
    { event_id: SecureRandom.uuid, metric: "lcp", value: 2_431.4, rating: "good",
      hostname: "acme.example", path: "/prezzi", environment: "production",
      navigation_type: "navigate", occurred_at: Time.current.iso8601 }.merge(over)
  end

  def invia(body)
    post "/api/v1/projects/#{project.id}/web_vitals", params: body.to_json, headers: headers
  end

  it "accetta una misura sola e la persiste con un solo giro in coda" do
    perform_enqueued_jobs do
      invia(misura)
    end

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    riga = Analytics::WebVital.last
    expect(riga.metric).to eq("lcp")
    expect(riga.value).to be_within(0.01).of(2_431.4)
    expect(riga.path).to eq("/prezzi")
    expect(riga.device_type).to eq("mobile")
  end

  it "accetta un batch" do
    perform_enqueued_jobs do
      invia([ misura, misura(metric: "cls", value: 0.04), misura(metric: "inp", value: 180) ])
    end

    expect(response.parsed_body.dig("data", "accepted")).to eq(3)
    expect(Analytics::WebVital.pluck(:metric)).to match_array(%w[lcp cls inp])
  end

  # L'esito lo decide il server: un client vecchio, con soglie superate, vedrebbe verde dove Google
  # vede rosso — e sarebbe il misurato a darsi il voto.
  it "ricalcola l'esito e non si fida di quello mandato dal client" do
    perform_enqueued_jobs do
      invia(misura(metric: "lcp", value: 9_000, rating: "good"))
    end

    expect(Analytics::WebVital.last.rating).to eq("poor")
  end

  # Basta una manciata di misure assurde per spostare il percentile di un sito intero.
  it "scarta i valori fuori da ogni scala invece di lasciarli avvelenare il percentile" do
    invia([ misura(value: 999_999), misura(metric: "cls", value: 50) ])

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-WEBVITAL-004")
  end

  it "una metrica che non conosciamo non entra" do
    invia(misura(metric: "inventata"))

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "un batch troppo grande viene rifiutato invece di essere troncato in silenzio" do
    invia(Array.new(Analytics::Constants::WEB_VITALS_MAX_BATCH + 1) { misura })

    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("R413-WEBVITAL-002")
  end

  # Idempotenza: il client può riprovare senza raddoppiare i numeri.
  it "lo stesso event_id non entra due volte" do
    identica = misura
    perform_enqueued_jobs do
      invia(identica)
      invia(identica)
    end

    expect(Analytics::WebVital.count).to eq(1)
  end

  # Chi non raccoglie le statistiche non raccoglie nemmeno queste. Non è un errore del client: si
  # accetta con zero, come per i bot, invece di punirlo con un 4xx che finirebbe nei suoi log.
  it "con la raccolta spenta risponde 202 con zero accettate, senza accodare" do
    project.update!(analytics_enabled: false)

    expect { invia(misura) }.not_to have_enqueued_job(Analytics::WebVitalsIngestJob)
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(0)
  end

  it "una richiesta da un bot non entra, e non è un errore" do
    expect do
      post "/api/v1/projects/#{project.id}/web_vitals", params: misura.to_json,
                                                        headers: headers.merge("HTTP_USER_AGENT" => "Googlebot/2.1")
    end.not_to have_enqueued_job(Analytics::WebVitalsIngestJob)
    expect(response).to have_http_status(:accepted)
  end

  it "il progetto del percorso deve essere quello del token" do
    altro = create(:project, organization:)

    post "/api/v1/projects/#{altro.id}/web_vitals", params: misura.to_json, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-WEBVITAL-001")
  end

  # BOUNDARY PII: gli argomenti dei job vivono su Postgres, quindi l'IP e lo user-agent grezzo non
  # devono uscire dal controller. E qui, a differenza dei pageview, non c'è nemmeno il visitor_hash.
  it "al job non arrivano né IP né user-agent, e nessun identificatore del visitatore" do
    invia(misura)

    accodato = enqueued_jobs.find { |job| job["job_class"] == "Analytics::WebVitalsIngestJob" }
    serializzato = accodato.to_json
    expect(serializzato).not_to include("203.0.113.9")
    expect(serializzato).not_to include("iPhone")
    expect(serializzato).not_to include("visitor_hash")
    expect(Analytics::WebVital.column_names).not_to include("visitor_hash")
  end
end
