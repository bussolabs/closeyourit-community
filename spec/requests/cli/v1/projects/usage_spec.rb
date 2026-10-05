# frozen_string_literal: true

require "rails_helper"

# CYSK-29 — la rilettura CLI: simboli visti e reporter vivi. Il verdetto «inutilizzato» non esce
# da qui: lo calcola lo scanner con l'inventario statico del repo.
RSpec.describe "Cli::V1::Projects::Usage", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "elenca i simboli visti, filtrabili per kind" do
    Usage::Symbol.create!(project:, environment: "production", kind: "route", symbol: "Users#index",
                          first_seen_at: 2.days.ago, last_seen_at: 1.hour.ago, hits_count: 7)
    Usage::Symbol.create!(project:, environment: "production", kind: "job", symbol: "MailJob",
                          first_seen_at: 2.days.ago, last_seen_at: 1.day.ago, hits_count: 1)

    get "/cli/v1/projects/#{project.id}/usage", headers:, params: { kind: "route" }

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data.size).to eq(1)
    expect(data.first["symbol"]).to eq("Users#index")
  end

  it "elenca i reporter: la risposta a «mai chiamata o SDK mai deployato?»" do
    Usage::Reporter.create!(project:, environment: "production", kind: "route", sdk_name: "closeyourit-ruby",
                            first_reported_at: 40.days.ago, last_reported_at: 5.minutes.ago)

    get "/cli/v1/projects/#{project.id}/usage/reporters", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].first["sdk_name"]).to eq("closeyourit-ruby")
  end

  it "progetto di un'altra organizzazione → 404 (anti-BOLA)" do
    estraneo = create(:project, organization: create(:organization))

    get "/cli/v1/projects/#{estraneo.id}/usage", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
