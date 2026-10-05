# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Analytics (stats API token utente)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before do
    create(:membership, account:, organization:, role: :owner)
    create_list(:pageview, 2, project:, path: "/home")
  end

  it "200 con lo snapshot del progetto visibile" do
    get "/cli/v1/projects/#{project.id}/analytics", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "summary", "pageviews")).to eq(2)
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/analytics"
    expect(response).to have_http_status(:unauthorized)
  end

  it "BOLA: progetto di un'altra org → 404" do
    other_org = create(:organization)
    foreign = create(:project, organization: other_org)
    get "/cli/v1/projects/#{foreign.id}/analytics", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
