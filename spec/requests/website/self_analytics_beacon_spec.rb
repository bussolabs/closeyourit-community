# frozen_string_literal: true

require "rails_helper"

# CYRA-238 — Beacon self-analytics (dogfooding): il canale pubblico manda un pageview al progetto
# CloseYourIt via DSN public key quando WEBSITE_ANALYTICS_PROJECT_ID/_KEY sono in ENV, no-op
# altrimenti (nessuno script, nessuna richiesta, nessun errore JS).
RSpec.describe "Website::SelfAnalyticsBeacon", type: :request do
  around do |example|
    original_project_id = ENV["WEBSITE_ANALYTICS_PROJECT_ID"]
    original_key = ENV["WEBSITE_ANALYTICS_KEY"]
    example.run
    ENV["WEBSITE_ANALYTICS_PROJECT_ID"] = original_project_id
    ENV["WEBSITE_ANALYTICS_KEY"] = original_key
  end

  it "config assente → nessuno script beacon emesso (no-op)" do
    ENV.delete("WEBSITE_ANALYTICS_PROJECT_ID")
    ENV.delete("WEBSITE_ANALYTICS_KEY")

    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("sendPageview")
    expect(response.body).not_to include("sendBeacon")
  end

  it "config presente → emette lo script beacon verso l'endpoint pageview del progetto self" do
    token = create(:project_token, :ingest_only)
    ENV["WEBSITE_ANALYTICS_PROJECT_ID"] = token.project.id.to_s
    ENV["WEBSITE_ANALYTICS_KEY"] = token.public_key

    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("sendBeacon")
    expect(response.body).to include("/api/v1/projects/#{token.project.id}/pageviews?sentry_key=#{token.public_key}")
    expect(response.body).to include('name: "pageview"')
  end
end
