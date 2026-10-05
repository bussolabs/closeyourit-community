# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Types::FeatureStatuses", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create(:membership, account:, organization:, role: :owner) }

  it "senza bearer → 401" do
    get "/cli/v1/types/feature_statuses"
    expect(response).to have_http_status(:unauthorized)
  end

  it "elenca gli stati ATTIVI dell'org, ordinati" do
    available = create(:feature_status, :available, organization:, position: 1)
    planned = create(:feature_status, organization:, code: "planned", position: 0)
    create(:feature_status, :inactive, organization:, code: "retired")

    get "/cli/v1/types/feature_statuses", headers: headers

    expect(response).to have_http_status(:ok)
    codes = response.parsed_body["data"].map { |status| status["code"] }
    expect(codes).to eq(%w[planned available])
    expect(codes).not_to include("retired")
    expect(response.parsed_body["data"].first).to include("id", "code", "label", "color", "category")
    expect(planned.id).to be_present
    expect(available.id).to be_present
  end

  it "esclude gli stati di un'altra org (anti-BOLA)" do
    create(:feature_status, code: "other_org_status") # altra org

    get "/cli/v1/types/feature_statuses", headers: headers

    expect(response.parsed_body["data"].map { |status| status["code"] }).not_to include("other_org_status")
  end
end
