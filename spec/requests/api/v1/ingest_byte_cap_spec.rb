# frozen_string_literal: true

require "rails_helper"

# CYRA-1039 — every ingest channel refuses an oversized body before authenticating and before
# parsing it. Events and metrics keep their own limit and code (CYRA-112, tested in their specs).
RSpec.describe "Api::V1 ingest byte cap", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, helpdesk_enabled: true) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:public_key) do
    Projects::Tokens::Issue.call(project:, name: "Site", host: "shop.example.com", environment:).value[:token].public_key
  end
  let(:headers) { { "X-Sentry-Auth" => "Sentry sentry_key=#{public_key}", "CONTENT_TYPE" => "application/json" } }

  %w[logs pageviews replays web_vitals helpdesk_requests].each do |channel|
    describe "POST /api/v1/projects/:id/#{channel}" do
      let(:body) { "[" + ("{\"message\":\"x\"}," * 3).chomp(",") + "]" }

      it "over the limit → 413 R413-INGEST-003 without parsing the body" do
        stub_const("Api::V1::IngestBaseController::MAX_BYTES", body.bytesize - 1)
        post "/api/v1/projects/#{project.id}/#{channel}", params: body, headers: headers
        expect(response).to have_http_status(:content_too_large)
        expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-003")
      end

      it "over the limit, without credentials and malformed → 413 (precedes auth and parse)" do
        stub_const("Api::V1::IngestBaseController::MAX_BYTES", 10)
        post "/api/v1/projects/#{project.id}/#{channel}",
             params: "{ malformed and well over ten bytes", headers: { "CONTENT_TYPE" => "application/json" }
        expect(response).to have_http_status(:content_too_large)
      end

      it "at the limit → not 413" do
        stub_const("Api::V1::IngestBaseController::MAX_BYTES", body.bytesize)
        post "/api/v1/projects/#{project.id}/#{channel}", params: body, headers: headers
        expect(response).not_to have_http_status(:content_too_large)
      end
    end
  end
end
