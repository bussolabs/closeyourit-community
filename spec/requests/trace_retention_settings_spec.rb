# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trace retention settings", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create(:membership, account:, organization:, role: :owner) }

  [ 1, 365 ].each do |days|
    it "persists and returns the project boundary of #{days} days" do
      put "/cli/v1/projects/#{project.id}/settings", headers:, params: { traces_retention_days: days }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").fetch("traces_retention_days")).to eq(days)
      expect(project.reload.traces_retention_days).to eq(days)
    end
  end

  [ 0, 366, 1.5, "invalid" ].each do |days|
    it "rejects invalid project retention #{days.inspect}" do
      put "/cli/v1/projects/#{project.id}/settings", headers:, params: { traces_retention_days: days }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.traces_retention_days).to be_nil
    end
  end

  it "keeps the trace override during unrelated updates" do
    project.update!(traces_retention_days: 30)
    put "/cli/v1/projects/#{project.id}/settings", headers:, params: { errors_retention_days: 40 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(project.reload.traces_retention_days).to eq(30)
  end

  it "clears the project override to inherit the organization value" do
    organization.update!(traces_retention_days: 45)
    project.update!(traces_retention_days: 30)
    put "/cli/v1/projects/#{project.id}/settings", headers:, params: { traces_retention_days: "" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(project.reload.traces_retention_days).to be_nil
    expect(Traces::Retention.for(project)).to eq(45)
  end

  it "updates and exposes the organization override through the CLI" do
    put "/cli/v1/organization", headers:, params: { confirm: "1", traces_retention_days: 60 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").fetch("traces_retention_days")).to eq(60)
    expect(organization.reload.traces_retention_days).to eq(60)
  end

  it "does not update a project outside the token organization" do
    foreign = create(:project)
    put "/cli/v1/projects/#{foreign.id}/settings", headers:, params: { traces_retention_days: 60 }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.traces_retention_days).to be_nil
  end

  it "requires authentication for trace retention changes" do
    put "/cli/v1/projects/#{project.id}/settings", params: { traces_retention_days: 60 }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(project.reload.traces_retention_days).to be_nil
  end

  it "accepts the member organization setting with the existing owner gate" do
    post login_path, params: { email: account.email, password: "Secret123!" }
    patch member_organization_path, params: { confirm: "1", traces_retention_days: 31 }
    expect(response).to have_http_status(:redirect)
    expect(organization.reload.traces_retention_days.to_i).to eq(31)
  end

  it "accepts the member project setting with the existing project gate" do
    post login_path, params: { email: account.email, password: "Secret123!" }
    patch member_project_settings_path(project), params: { confirm: "1", traces_retention_days: 32 }
    expect(response).to have_http_status(:redirect)
    expect(project.reload.traces_retention_days.to_i).to eq(32)
  end

  it "accepts the global setting only through the existing god gate" do
    account.update!(god: true)
    enable_two_factor!(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account)
    patch valhalla_settings_path, params: { traces_retention_days: 33 }
    expect(response).to have_http_status(:redirect)
    expect(Settings::Global.instance.traces_retention_days).to eq(33)
  end
end
