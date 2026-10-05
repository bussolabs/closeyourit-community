# frozen_string_literal: true

require "rails_helper"

# CYRA-229: endpoint di raccolta delle violazioni CSP (report-uri della policy report-only). Il browser
# invia qui, same-origin, ogni risorsa che l'enforce bloccherebbe. Raccoglierle server-side permette di
# dimostrare "zero violazioni" prima di passare all'enforce, senza dipendere dalla console del browser.
RSpec.describe "CSP reports", type: :request do
  let(:report) do
    {
      "csp-report" => {
        "document-uri" => "https://www.closeyour.it/",
        "violated-directive" => "font-src",
        "blocked-uri" => "https://fonts.gstatic.com/s/inter/x.woff2"
      }
    }
  end

  def post_report(body)
    post "/csp-reports", params: body, headers: { "CONTENT_TYPE" => "application/csp-report" }
  end

  it "accetta il report del browser e risponde 204 No Content" do
    post_report(report.to_json)
    expect(response).to have_http_status(:no_content)
  end

  it "registra la violazione nei log (punto di raccolta osservabile)" do
    allow(Rails.logger).to receive(:warn)
    post_report(report.to_json)
    expect(Rails.logger).to have_received(:warn).with(a_string_including("fonts.gstatic.com"))
  end

  it "un corpo malformato non solleva e risponde comunque 204" do
    post_report("not-a-json-body")
    expect(response).to have_http_status(:no_content)
  end

  it "neutralizza le andate a capo del corpo per non forgiare righe di log false" do
    logged = nil
    allow(Rails.logger).to receive(:warn) { |message| logged = message }

    post_report("prima riga\n[csp-report] blocked-uri: riga-forgiata")

    expect(logged).to be_present
    expect(logged).not_to include("\n"), "un corpo con a capo non deve poter iniettare righe di log"
    expect(logged).to include("prima riga")
  end

  it "non carica in memoria né logga per intero un corpo oltre il limite" do
    logged = nil
    allow(Rails.logger).to receive(:warn) { |message| logged = message }

    post_report("x" * 50_000)

    expect(response).to have_http_status(:no_content)
    expect(logged.to_s.length).to be <= CspReportsController::MAX_REPORT_BYTES + 64
  end
end
