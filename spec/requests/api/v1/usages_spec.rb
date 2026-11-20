# frozen_string_literal: true

require "rails_helper"

# CYSK-29 — il canale della telemetria d'uso: flush di simboli visti, upsert con GREATEST, mai URL.
RSpec.describe "Api::V1::Usages", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:token) do
    Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  def flush_payload(symbols:, truncated: false)
    { environment: "production", release: "a1b2c3d",
      sdk: { name: "closeyourit-ruby", version: "0.9.0" },
      truncated: truncated, symbols: symbols }
  end

  it "accetta un flush, fonde con GREATEST e registra il reporter del kind" do
    prima = 2.hours.ago.iso8601
    dopo = 1.minute.ago.iso8601

    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(symbols: [
           { kind: "route", symbol: "Admin::UsersController#index", count: 42, last_seen_at: dopo }
         ])
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    perform_enqueued_jobs

    # Un secondo flush PIÙ VECCHIO non riporta indietro last_seen_at, ma somma gli hit.
    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(symbols: [
           { kind: "route", symbol: "Admin::UsersController#index", count: 3, last_seen_at: prima }
         ])
    perform_enqueued_jobs

    symbol = Usage::Symbol.sole
    aggregate_failures do
      expect(symbol.symbol).to eq("Admin::UsersController#index")
      expect(symbol.last_seen_at).to be_within(1.second).of(Time.iso8601(dopo))
      expect(symbol.hits_count).to eq(45)
      expect(Usage::Reporter.sole).to have_attributes(kind: "route", sdk_name: "closeyourit-ruby")
    end
  end

  it "scarta le voci fuori contratto senza bocciare il flush: un simbolo interpolato non entra" do
    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(symbols: [
           { kind: "route", symbol: "Users#show", count: 1, last_seen_at: Time.current.iso8601 },
           { kind: "route", symbol: "/users/42?token=abc", count: 1, last_seen_at: Time.current.iso8601 },
           { kind: "inventato", symbol: "X", count: 1, last_seen_at: Time.current.iso8601 }
         ])

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    perform_enqueued_jobs
    expect(Usage::Symbol.pluck(:symbol)).to eq([ "Users#show" ])
  end

  # CYRA-1232 — una voce ripetuta faceva cadere l'upsert intero: si perdevano anche quelle buone.
  it "una voce ripetuta nello stesso flush si fonde e le altre voci si salvano lo stesso" do
    prima = 2.hours.ago.iso8601
    dopo = 1.minute.ago.iso8601

    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(symbols: [
           { kind: "route", symbol: "Users#show", count: 2, last_seen_at: prima },
           { kind: "job", symbol: "Billing::InvoiceJob", count: 7, last_seen_at: dopo },
           { kind: "route", symbol: "Users#show", count: 3, last_seen_at: dopo }
         ])
    # La risposta conta le voci ricevute, non quelle distinte: il contratto del canale non cambia.
    expect(response.parsed_body.dig("data", "accepted")).to eq(3)
    perform_enqueued_jobs

    ripetuto = Usage::Symbol.find_by!(kind: "route", symbol: "Users#show")
    aggregate_failures do
      expect(Usage::Symbol.pluck(:symbol)).to contain_exactly("Users#show", "Billing::InvoiceJob")
      expect(ripetuto.hits_count).to eq(5)
      expect(ripetuto.first_seen_at).to be_within(1.second).of(Time.iso8601(prima))
      expect(ripetuto.last_seen_at).to be_within(1.second).of(Time.iso8601(dopo))
      expect(Usage::Symbol.find_by!(symbol: "Billing::InvoiceJob").hits_count).to eq(7)
      expect(Usage::Reporter.pluck(:kind)).to contain_exactly("route", "job")
    end
  end

  it "il tetto degli hit si applica dopo la somma delle voci ripetute" do
    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(symbols: [
           { kind: "route", symbol: "Users#show", count: 2**40, last_seen_at: Time.current.iso8601 },
           { kind: "route", symbol: "Users#show", count: 1, last_seen_at: Time.current.iso8601 }
         ])
    perform_enqueued_jobs

    expect(Usage::Symbol.sole.hits_count).to eq(2**40)
  end

  # I due upsert sono una transazione sola: se il reporter cade, anche i simboli si annullano e il
  # ritentativo li scrive una volta, non due.
  it "un guasto passeggero sul reporter si ritenta senza raddoppiare gli hit" do
    guasti = 1
    allow(Usage::Reporter).to receive(:upsert_all).and_wrap_original do |original, *args, **kwargs|
      if guasti.positive?
        guasti -= 1
        raise ActiveRecord::Deadlocked, "contesa simulata"
      end
      original.call(*args, **kwargs)
    end

    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(symbols: [
           { kind: "route", symbol: "Users#show", count: 4, last_seen_at: Time.current.iso8601 }
         ])

    # A mano quello che farebbe il motore delle code: il primo giro cade e rimette in coda il lavoro.
    ActiveJob::Base.execute(enqueued_jobs.shift)
    expect(Usage::Symbol.count).to eq(0)
    expect(enqueued_jobs.size).to eq(1)

    ActiveJob::Base.execute(enqueued_jobs.shift)
    aggregate_failures do
      expect(Usage::Symbol.sole.hits_count).to eq(4)
      expect(Usage::Reporter.sole.kind).to eq("route")
    end
  end

  it "il flag truncated arriva sul reporter: è quello che squalifica il kind presso lo scanner" do
    post "/api/v1/projects/#{project.id}/usages", headers:, as: :json,
         params: flush_payload(truncated: true, symbols: [
           { kind: "job", symbol: "Billing::InvoiceJob", count: 1, last_seen_at: Time.current.iso8601 }
         ])
    perform_enqueued_jobs

    expect(Usage::Reporter.sole.truncated_last_window).to be(true)
  end

  it "senza bearer → 401: la DSN public key non apre questo canale" do
    post "/api/v1/projects/#{project.id}/usages", params: { symbols: [] }

    expect(response).to have_http_status(:unauthorized)
  end
end
