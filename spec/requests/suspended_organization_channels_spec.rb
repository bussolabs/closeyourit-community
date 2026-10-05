# frozen_string_literal: true

require "rails_helper"

# CYRA-722 — la sospensione di un'organizzazione vale su OGNI canale, non solo nel browser: chiudere
# la porta d'ingresso e lasciare aperte quelle delle macchine vorrebbe dire che l'organizzazione
# sospesa continua a mandare dati, a leggerli e a farsi servire dalla riga di comando. Il rifiuto è
# lo stesso ovunque: 403 R403-ORGANIZATION-002, così chi lo riceve capisce che non è un problema di
# credenziale ma dell'organizzazione.
RSpec.describe "Organizzazione sospesa — canali a token", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:issued) do
    Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment:
    ).value
  end
  let(:bearer) { { "Authorization" => "Bearer #{issued[:secret]}", "CONTENT_TYPE" => "application/json" } }
  let(:public_key) { issued[:token].public_key }
  let(:evento) { { "event_id" => SecureRandom.uuid, "level" => "error", "message" => "boom" }.to_json }

  def codice = response.parsed_body.dig("error", "code")

  context "API a token di progetto" do
    before { organization.update!(suspended_at: Time.current) }

    it "l'ingest degli errori è rifiutato" do
      post "/api/v1/projects/#{project.id}/events", params: evento, headers: bearer

      expect(response).to have_http_status(:forbidden)
      expect(codice).to eq("R403-ORGANIZATION-002")
    end

    it "la lettura della telemetria è rifiutata" do
      get "/api/v1/error_groups", headers: bearer

      expect(response).to have_http_status(:forbidden)
      expect(codice).to eq("R403-ORGANIZATION-002")
    end

    it "riattivare l'organizzazione riapre l'ingest" do
      organization.update!(suspended_at: nil)

      post "/api/v1/projects/#{project.id}/events", params: evento, headers: bearer
      expect(response).to have_http_status(:accepted)
    end
  end

  context "ingest dal browser con la DSN pubblica" do
    before { organization.update!(suspended_at: Time.current) }

    it "è rifiutato come il bearer" do
      post "/api/v1/projects/#{project.id}/events?sentry_key=#{public_key}",
           params: evento, headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:forbidden)
      expect(codice).to eq("R403-ORGANIZATION-002")
    end

    it "anche sulla rotta Sentry compatibile" do
      post "/api/#{project.id}/store?sentry_key=#{public_key}",
           params: evento, headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:forbidden)
      expect(codice).to eq("R403-ORGANIZATION-002")
    end
  end

  context "riga di comando (token utente)" do
    let(:account) { create(:account) }
    let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
    let(:headers) { { "Authorization" => "Bearer #{secret}" } }

    before { create(:membership, account:, organization:, role: :owner) }

    it "rifiuta la lettura quando l'organizzazione è sospesa" do
      secret
      organization.update!(suspended_at: Time.current)

      get "/cli/v1/organization", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(codice).to eq("R403-ORGANIZATION-002")
    end

    it "torna a rispondere quando l'organizzazione è riattivata" do
      get "/cli/v1/organization", headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  context "sonde di monitoraggio dei server" do
    let(:enrollment) { Servers::EnrollmentTokens::Issue.call(organization:, name: "flotta").value[:secret] }

    it "rifiuta i campioni di un'organizzazione sospesa" do
      headers = { "Authorization" => "Bearer #{enrollment}", "CONTENT_TYPE" => "application/json" }
      organization.update!(suspended_at: Time.current)

      post "/api/v1/servers/samples", params: { hostname: "web-1" }.to_json, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(codice).to eq("R403-ORGANIZATION-002")
    end
  end
end
