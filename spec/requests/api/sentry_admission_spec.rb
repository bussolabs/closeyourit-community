# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sentry numeric admission", type: :request do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:token) { create(:project_token, project: project, scopes: [ "ingest" ]) }
  let(:headers) { { "X-Sentry-Auth" => "Sentry sentry_key=#{token.public_key}", "CONTENT_TYPE" => "application/x-sentry-envelope" } }
  let(:body) { "{\"event_id\":\"admission-id\"}\n{\"type\":\"event\"}\n{\"message\":\"hello\"}\n" }

  def endpoint
    "/api/#{project.reload.sentry_project_id}/envelope/"
  end

  it "provides a separate numeric DSN and preserves native UUID DSNs" do
    expect(token.to_sentry_dsn(host: "ingest.example.test")).to end_with("/#{project.reload.sentry_project_id}")
    expect(token.to_dsn(host: "ingest.example.test")).to end_with("/#{project.id}")
    expect(project.sentry_project_id).to be_positive
  end

  it "authenticates numeric aliases and retains header-only event identifiers" do
    post endpoint, params: body, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["id"]).to eq("admission-id")
    expect(Errors::IngestPayload.sole.payload["event_id"]).to eq("admission-id")
  end

  it "preserves official Node request bodies when Content-Type is absent" do
    reads = []
    input = StringIO.new(body)
    input.define_singleton_method(:read) do |*arguments|
      reads << arguments.first
      super(*arguments)
    end
    env = Rack::MockRequest.env_for(endpoint, method: "POST", input: input,
                                   "HTTP_X_SENTRY_AUTH" => headers.fetch("X-Sentry-Auth"))
    env.delete("CONTENT_TYPE")
    status, _response_headers, response_body = Rails.application.call(env)
    response_body.close if response_body.respond_to?(:close)
    expect(env["CONTENT_TYPE"]).to be_nil
    expect(reads).to eq([ Errors::Ingest::EnvelopeParser::MAX_COMPRESSED + 1 ])
    expect(status).to eq(200)
    expect(Errors::IngestPayload.sole.payload["event_id"]).to eq("admission-id")
  end

  [ "application/json", "application/x-www-form-urlencoded", nil ].each do |content_type|
    it "enforces the raw byte cap before parsing store requests with #{content_type || 'no content type'}" do
      reads = []
      input = StringIO.new("x" * (Errors::Ingest::EnvelopeParser::MAX_COMPRESSED + 20))
      input.define_singleton_method(:read) do |*arguments|
        reads << arguments.first
        super(*arguments)
      end
      env = Rack::MockRequest.env_for("/api/#{project.reload.sentry_project_id}/store/", method: "POST", input: input,
                                     "HTTP_X_SENTRY_AUTH" => headers.fetch("X-Sentry-Auth"))
      env["CONTENT_TYPE"] = content_type
      status, _response_headers, response_body = Rails.application.call(env)
      response_body.close if response_body.respond_to?(:close)
      expect(status).to eq(413)
      expect(reads).to eq([ Errors::Ingest::EnvelopeParser::MAX_COMPRESSED + 1 ])
      expect(env["CONTENT_TYPE"]).to eq(content_type)
      expect(Errors::IngestPayload.count).to eq(0)
    end
  end

  it "accepts gzip store bytes with a JSON content type without framework JSON parsing" do
    post "/api/#{project.reload.sentry_project_id}/store/", params: Zlib.gzip({ event_id: "gzip-json", message: "Hello" }.to_json),
         headers: headers.merge("CONTENT_TYPE" => "application/json", "Content-Encoding" => "gzip")
    expect(response).to have_http_status(:ok)
    expect(Errors::IngestPayload.sole.payload["event_id"]).to eq("gzip-json")
  end

  it "rejects another project's alias and read-only public keys" do
    other = create(:project)
    post "/api/#{other.reload.sentry_project_id}/envelope/", params: body, headers: headers
    expect(response).to have_http_status(:unauthorized)
    token.update!(scopes: [ "read" ])
    post endpoint, params: body, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(Errors::IngestPayload.count).to eq(0)
  end

  it "rejects conflicting header and query keys" do
    post "#{endpoint}?sentry_key=deadbeef", params: body, headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an envelope DSN that conflicts with the authenticated project" do
    conflicting = body.sub("{\"event_id\":\"admission-id\"}", { event_id: "admission-id", dsn: "https://deadbeef@ingest.example.test/#{project.reload.sentry_project_id}" }.to_json)
    post endpoint, params: conflicting, headers: headers
    expect(response).to have_http_status(:unauthorized)
    expect(Errors::IngestPayload.count).to eq(0)
  end

  it "rejects malformed native event structures before shared normalization" do
    post "/api/v1/projects/#{project.id}/events", params: { exception: { values: [ 42 ] } }.to_json,
         headers: headers.merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:unprocessable_content)
    expect(Errors::IngestPayload.count).to eq(0)
  end

  it "diagnoses unsupported items without storing their payloads" do
    post endpoint, params: "{}\n{\"type\":\"client_report\"}\n{}\n{\"type\":\"arbitrary-secret\"}\n{}\n", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["id"]).to be_nil
    expect(JSON.parse(response.headers["X-CloseYourIt-Ignored-Items"])).to eq("client_report" => 1, "unknown" => 1)
    expect(Errors::IngestPayload.count).to eq(0)
  end

  it "rejects multiple events sharing one envelope identifier before any staging" do
    post endpoint, params: body + "{\"type\":\"event\"}\n{\"event_id\":\"another\"}\n", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(Errors::IngestPayload.count).to eq(0)
  end

  it "retains the legacy multiple-event extension when every event has its own identifier" do
    events = "{}\n{\"type\":\"event\"}\n{\"event_id\":\"first\"}\n{\"type\":\"event\"}\n{\"event_id\":\"second\"}\n"
    post endpoint, params: events, headers: headers
    expect(response).to have_http_status(:ok)
    expect(Errors::IngestPayload.all.map { |row| row.payload["event_id"] }).to contain_exactly("first", "second")
  end

  it "rejects unsupported compression and malformed event structures" do
    post endpoint, params: body, headers: headers.merge("Content-Encoding" => "br")
    expect(response).to have_http_status(:unsupported_media_type)
    post endpoint, params: "{}\n{\"type\":\"event\"}\n{\"exception\":42}\n", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "permits only Sentry ingest CORS preflights and exposes diagnostics" do
    options endpoint, headers: { "Origin" => "https://client.example.test", "Access-Control-Request-Method" => "POST", "Access-Control-Request-Headers" => "x-sentry-auth,content-type" }
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
    expect(response.headers["Access-Control-Expose-Headers"]).to include("X-CloseYourIt-Ignored-Items")
    options "/api/#{project.id}/settings", headers: { "Origin" => "https://client.example.test", "Access-Control-Request-Method" => "POST" }
    expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
  end

  it "shares the rate-limit key between numeric and UUID aliases" do
    numeric = Rack::Request.new(Rack::MockRequest.env_for(endpoint, method: "POST"))
    legacy = Rack::Request.new(Rack::MockRequest.env_for("/api/#{project.id}/store", method: "POST"))
    expect(Rack::Attack.ingest_project_key(numeric, Rack::Attack::INGEST_ENVELOPE_STORE_PATH))
      .to eq(Rack::Attack.ingest_project_key(legacy, Rack::Attack::INGEST_ENVELOPE_STORE_PATH))
  end
end
