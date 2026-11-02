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

  # CYRA-1124 — with no declared size (chunked, or no Content-Length at all) the cap counts the bytes
  # received, and still runs before authentication and parse.
  describe "without a declared size" do
    let(:event) { { "event_id" => "feedface", "level" => "error", "message" => "x" * 64 }.to_json }
    let(:chunked) { { "Transfer-Encoding" => "chunked", "CONTENT_LENGTH" => "", "CONTENT_TYPE" => "application/json" } }

    it "a chunked event over the events cap, without credentials → 413 R413-INGEST-002" do
      stub_const("Errors::Constants::EVENTS_MAX_BYTES", event.bytesize - 1)
      post "/api/v1/projects/#{project.id}/events", params: event, headers: chunked
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-002")
    end

    it "an event with no Content-Length over the events cap → 413 R413-INGEST-002" do
      stub_const("Errors::Constants::EVENTS_MAX_BYTES", event.bytesize - 1)
      post "/api/v1/projects/#{project.id}/events", params: event,
           headers: headers.merge("CONTENT_LENGTH" => "")
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-002")
    end

    it "chunked metrics over the metrics cap → 413 R413-METRIC-006" do
      stub_const("Metrics::Constants::MAX_BYTES", 10)
      post "/api/v1/projects/#{project.id}/metrics", params: "{ malformed and well over ten bytes", headers: chunked
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-METRIC-006")
    end

    it "a chunked log batch over the shared cap → 413 R413-INGEST-003" do
      stub_const("Api::V1::IngestBaseController::MAX_BYTES", 10)
      post "/api/v1/projects/#{project.id}/logs", params: "[{\"message\":\"well over ten bytes\"}]", headers: chunked
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-003")
    end

    it "a chunked event of normal size is measured, then read and accepted as today" do
      post "/api/v1/projects/#{project.id}/events", params: event, headers: headers.merge(chunked)
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "id")).to eq("feedface")
    end
  end
end
