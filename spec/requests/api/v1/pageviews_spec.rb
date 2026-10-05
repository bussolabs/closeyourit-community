# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Pageviews (ingest bearer)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  # analytics_enabled: true → l'ingest è gata dal toggle Settings "Raccogli analytics" (opt-in, default false).
  let(:project) { create(:project, organization:, analytics_enabled: true) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "Browser", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:chrome_ua) do
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  end
  let(:headers) do
    { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json",
      "HTTP_USER_AGENT" => chrome_ua, "REMOTE_ADDR" => "203.0.113.9" }
  end

  def pageview(over = {})
    { "event_id" => SecureRandom.uuid, "hostname" => "www.example.test", "path" => "/articles/foo",
      "occurred_at" => Time.current.iso8601 }.merge(over)
  end

  it "bearer valido + array → 202 { data: { accepted } } e un solo IngestJob batch" do
    body = [ pageview, pageview, pageview ]
    expect do
      post "/api/v1/projects/#{project.id}/pageviews", params: body.to_json, headers: headers
    end.to have_enqueued_job(Analytics::IngestJob).once

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(3)
  end

  it "accetta anche un singolo oggetto" do
    expect do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json, headers: headers
    end.to have_enqueued_job(Analytics::IngestJob).once

    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
  end

  it "end-to-end: il job crea i pageview con visitor_hash e browser/os derivati" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: [ pageview, pageview ].to_json, headers: headers
    end

    expect(project.analytics_pageviews.count).to eq(2)
    row = project.analytics_pageviews.first
    expect(row.visitor_hash).to match(/\A[0-9a-f]{64}\z/)
    expect(row.browser).to eq("Chrome")
    expect(row.os).to eq("macOS")
  end

  it "BOUNDARY PII: gli argomenti del job non contengono MAI ip né user_agent raw" do
    post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json, headers: headers

    raw_args = enqueued_jobs.last[:args].to_json
    expect(raw_args).not_to include("203.0.113.9")
    expect(raw_args).not_to include("Mozilla")
    expect(raw_args).to include("visitor_hash")
  end

  it "geo: il country risolto dall'IP finisce nella riga; l'IP resta fuori (consumato inline)" do
    allow(Analytics::Geo).to receive(:country_code).with("203.0.113.9").and_return("IT")
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json, headers: headers
    end

    expect(project.analytics_pageviews.sole.country_code).to eq("IT")
  end

  it "geo: DB assente in test → country_code nil, l'ingest non fallisce" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json, headers: headers
    end

    expect(project.analytics_pageviews.sole.country_code).to be_nil
  end

  it "stesso visitatore nello stesso giorno → stesso visitor_hash; IP diverso → hash diverso" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json, headers: headers
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json, headers: headers
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json,
           headers: headers.merge("REMOTE_ADDR" => "198.51.100.7")
    end

    hashes = project.analytics_pageviews.pluck(:visitor_hash)
    expect(hashes.tally.values.sort).to eq([ 1, 2 ])
  end

  it "normalizza referrer esterno al solo hostname e scarta il referrer same-host" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: [
        pageview("referrer" => "https://www.google.com/search?q=closeyourit"),
        pageview("referrer" => "https://www.example.test/altra-pagina")
      ].to_json, headers: headers
    end

    expect(project.analytics_pageviews.pluck(:referrer_host)).to contain_exactly("www.google.com", nil)
  end

  it "persiste gli UTM e tronca la query dal path" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview(
        "path" => "/landing?utm_source=newsletter", "utm_source" => "newsletter", "utm_medium" => "email"
      ).to_json, headers: headers
    end

    row = project.analytics_pageviews.sole
    expect(row.path).to eq("/landing")
    expect(row.utm_source).to eq("newsletter")
    expect(row.utm_medium).to eq("email")
  end

  it "custom event (name) end-to-end: la riga porta il nome dell'evento" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview("name" => "Signup").to_json, headers: headers
    end

    expect(project.analytics_pageviews.sole.name).to eq("Signup")
  end

  it "idempotenza: stesso event_id due volte → una sola riga" do
    body = pageview("event_id" => "11111111-2222-3333-4444-555555555555")
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews", params: body.to_json, headers: headers
      post "/api/v1/projects/#{project.id}/pageviews", params: body.to_json, headers: headers
    end

    expect(project.analytics_pageviews.count).to eq(1)
  end

  context "toggle 'Raccogli analytics' OFF sul progetto" do
    let(:project) { create(:project, organization:, analytics_enabled: false) }

    it "202 { accepted: 0 } senza enqueue: l'ingest è gata dal toggle" do
      expect do
        post "/api/v1/projects/#{project.id}/pageviews", params: [ pageview, pageview ].to_json, headers: headers
      end.not_to have_enqueued_job(Analytics::IngestJob)

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "accepted")).to eq(0)
      expect(project.analytics_pageviews.count).to eq(0)
    end
  end

  it "richiesta da bot/crawler → 202 { accepted: 0 } senza enqueue" do
    expect do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json,
           headers: headers.merge("HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1)")
    end.not_to have_enqueued_job(Analytics::IngestJob)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(0)
  end

  it "User-Agent assente → trattato come bot (nessun browser reale), accepted: 0" do
    expect do
      post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json,
           headers: headers.except("HTTP_USER_AGENT")
    end.not_to have_enqueued_job(Analytics::IngestJob)

    expect(response.parsed_body.dig("data", "accepted")).to eq(0)
  end

  it "senza bearer → 401" do
    post "/api/v1/projects/#{project.id}/pageviews", params: pageview.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "BOLA: project_id del path ≠ progetto del token → 404 con envelope" do
    other = create(:project, organization:)
    post "/api/v1/projects/#{other.id}/pageviews", params: pageview.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-PAGEVIEW-001")
  end

  it "batch oltre ANALYTICS_MAX_BATCH → 413 R413-PAGEVIEW-002, nessun job" do
    body = Array.new(Analytics::Constants::MAX_BATCH + 1) { pageview }
    expect do
      post "/api/v1/projects/#{project.id}/pageviews", params: body.to_json, headers: headers
    end.not_to have_enqueued_job(Analytics::IngestJob)

    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("R413-PAGEVIEW-002")
  end

  it "batch non vuoto interamente scartato (senza hostname/path) → 422 R422-PAGEVIEW-004" do
    expect do
      post "/api/v1/projects/#{project.id}/pageviews", params: [ { "foo" => "bar" } ].to_json, headers: headers
    end.not_to have_enqueued_job(Analytics::IngestJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-PAGEVIEW-004")
  end

  it "batch parziale (validi + scartabili) → 202 col conteggio dei soli validi" do
    perform_enqueued_jobs do
      post "/api/v1/projects/#{project.id}/pageviews",
           params: [ pageview, { "foo" => "bar" } ].to_json, headers: headers
    end

    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    expect(project.analytics_pageviews.count).to eq(1)
  end

  it "body malformato → 422 R422-PAGEVIEW-001" do
    post "/api/v1/projects/#{project.id}/pageviews", params: "{non-json", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-PAGEVIEW-001")
  end
end
