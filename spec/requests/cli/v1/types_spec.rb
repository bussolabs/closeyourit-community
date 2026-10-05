# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Types (lookup)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "environments → 200 con gli environment dell'org" do
    env = create(:environment, organization:)
    get "/cli/v1/types/environments", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].map { |e| e["id"] }).to include(env.id)
  end

  it "platforms → 200" do
    platform = create(:platform, organization:)
    get "/cli/v1/types/platforms", headers: headers
    expect(response.parsed_body["data"].map { |p| p["id"] }).to include(platform.id)
  end

  it "ticket_statuses → 200" do
    status = create(:ticket_status, organization:)
    get "/cli/v1/types/ticket_statuses", headers: headers
    expect(response.parsed_body["data"].map { |s| s["id"] }).to include(status.id)
  end

  it "ticket_priorities → 200" do
    priority = create(:ticket_priority, organization:)
    get "/cli/v1/types/ticket_priorities", headers: headers
    expect(response.parsed_body["data"].map { |p| p["id"] }).to include(priority.id)
  end

  it "senza bearer → 401" do
    get "/cli/v1/types/environments"
    expect(response).to have_http_status(:unauthorized)
  end
end
