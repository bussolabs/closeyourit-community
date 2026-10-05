# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sentry session health", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "Sessions", scopes: %w[ingest read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}" } }
  let(:ingest_path) { "/api/#{project.sentry_project_id}/envelope/?sentry_key=#{credential[:token].public_key}" }
  let(:payload) { { sid: SecureRandom.uuid, init: true, started: "2026-10-04T01:00:00Z", timestamp: "2026-10-04T01:01:00Z", status: "exited", attrs: { release: "v1", environment: "production", ip_address: "127.0.0.1" }, did: "alice@example.test" } }

  def envelope(*items)
    ([ {}.to_json ] + items.flat_map { |type, item| [ { type: type }.to_json, item.to_json ] }).join("\n")
  end

  it "persists supported session items before acknowledging and exposes only scrubbed project data" do
    post ingest_path, params: envelope([ "session", payload ]), headers: { "Content-Type" => "application/x-sentry-envelope" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("id" => nil)
    expect(JSON.parse(response.headers["X-CloseYourIt-Session-Results"])).to include("accepted" => 1)
    get "/api/v1/session_health/sessions", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole).to include("sid" => payload[:sid], "status" => "exited", "sequence" => "0", "errors" => "0")
    expect(response.body).not_to include("alice@example.test", "127.0.0.1")
    get "/api/v1/session_health/summaries", headers: headers
    expect(response.parsed_body.fetch("data").sole).to include("denominator" => "1", "numerator" => "1", "crash_free_rate" => 1.0)
  end

  it "validates an entire mixed envelope before enqueueing its error or storing a session" do
    bad = payload.merge(sid: "invalid")
    post ingest_path, params: envelope([ "event", { event_id: "a" * 32, message: "valid error" } ], [ "session", bad ])
    expect(response).to have_http_status(:unprocessable_content)
    expect(project.health_sessions.count).to eq(0)
    expect(Errors::IngestPayload.where(project_id: project.id).count).to eq(0)
  end

  it "stores valid session and error items through their separate pipelines" do
    expect do
      post ingest_path, params: envelope([ "event", { event_id: "a" * 32, message: "valid error" } ], [ "session", payload ])
    end.to have_enqueued_job(Errors::IngestJob)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["id"]).to eq("a" * 32)
    expect(project.health_sessions.count).to eq(1)
  end

  it "keeps aggregate counts separate and exposes the absence of delivery identities" do
    aggregates = { attrs: payload[:attrs], aggregates: [ { started: payload[:started], exited: 2, errored: 1, crashed: 1, abnormal: 1 } ] }
    post ingest_path, params: envelope([ "sessions", aggregates ], [ "session", payload ])
    expect(response).to have_http_status(:ok)
    get "/api/v1/session_health/summaries", params: { source: "aggregate", per: 1 }, headers: headers
    expect(response.parsed_body.fetch("data").sole).to include("source" => "aggregate", "deduplication" => "unavailable", "denominator" => "4", "numerator" => "3", "crash_free_rate" => 0.75)
    expect(response.parsed_body.dig("meta", "total")).to eq(1)
  end

  it "enforces read scope and project isolation even when the client supplies another project identifier" do
    post ingest_path, params: envelope([ "session", payload ])
    other = create(:project)
    other_environment = create(:environment, organization: other.organization).tap { |item| other.environments << item }
    other_secret = Projects::Tokens::Issue.call(project: other, environment: other_environment, host: "localhost", name: "Other", scopes: [ "read" ]).value[:secret]
    get "/api/v1/session_health/sessions", params: { project_id: project.id }, headers: { "Authorization" => "Bearer #{other_secret}" }
    expect(response.parsed_body.fetch("data")).to eq([])
    credential[:token].update!(scopes: [ "ingest" ])
    get "/api/v1/session_health/summaries", headers: headers
    expect(response).to have_http_status(:forbidden)
  end
  it "rejects malformed read identifiers" do
    get "/api/v1/session_health/sessions", params: { sid: "not-a-uuid" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "does not admit sessions under a conflicting envelope DSN" do
    body = envelope([ "session", payload ])
    body = body.sub("{}", { dsn: "http://wrong@localhost/#{project.sentry_project_id}" }.to_json)
    post ingest_path, params: body
    expect(response).to have_http_status(:unauthorized)
    expect(project.health_sessions.count).to eq(0)
  end

  it "returns retryable database failures without a successful admission notification" do
    allow(SessionHealth::Ingest::Record).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "private details")
    notifications = []
    handler = ->(_name, _start, _finish, _id, data) { notifications << data }
    ActiveSupport::Notifications.subscribed(handler, "sentry.ingest") { post ingest_path, params: envelope([ "session", payload ]) }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private details")
    expect(notifications).to eq([])
  end
  it "enforces the one-thousand-session budget across multiple envelope items before admission" do
    group = { started: payload[:started], exited: 1 }
    first = { attrs: payload[:attrs], aggregates: Array.new(500) { group } }
    second = { attrs: payload[:attrs], aggregates: Array.new(501) { group } }
    body = envelope([ "sessions", first ], [ "sessions", second ])
    post ingest_path, params: body
    expect(response).to have_http_status(:content_too_large)
    expect(project.health_aggregates.count).to eq(0)
    second[:aggregates].pop
    post ingest_path, params: envelope([ "sessions", first ], [ "sessions", second ])
    expect(response).to have_http_status(:ok)
    expect(project.health_aggregates.count).to eq(1_000)
  end
end
