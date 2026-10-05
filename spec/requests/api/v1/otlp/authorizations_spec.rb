# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OTLP project authorization", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:path) { "/api/v1/otlp/authorizations" }

  def issue(scopes: [ "ingest" ])
    Projects::Tokens::Issue.call(project:, environment:, host: "localhost", name: "OTLP", scopes:).value
  end

  it "returns only the authenticated tenant and ignores caller-supplied tenant selectors" do
    credential = issue
    post path, params: { organization_id: "untrusted", project_id: "untrusted" },
               headers: { "Authorization" => "Bearer #{credential[:secret]}" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => { "organization_id" => project.organization_id, "project_id" => project.id })
    expect(response.body).not_to include(credential[:secret], credential[:token].public_key)
  end

  it "rejects missing, invalid and public credentials" do
    public_key = issue[:token].public_key
    [ {}, { "Authorization" => "Bearer invalid" }, { "X-Sentry-Auth" => "Sentry sentry_key=#{public_key}" } ].each do |headers|
      post(path, headers:)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end
  end

  it "rejects read-only credentials" do
    credential = issue(scopes: [ "read" ])
    post path, headers: { "Authorization" => "Bearer #{credential[:secret]}" }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-AUTH-002")
  end

  %i[revoked_at expires_at].each do |attribute|
    it "rejects credentials with past #{attribute}" do
      credential = issue
      credential[:token].update!(attribute => 1.second.ago)
      post path, headers: { "Authorization" => "Bearer #{credential[:secret]}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "rejects a suspended organization before admission" do
    credential = issue
    project.organization.update!(suspended_at: Time.current)
    post path, headers: { "Authorization" => "Bearer #{credential[:secret]}" }
    expect(response).to have_http_status(:forbidden)
  end
end
