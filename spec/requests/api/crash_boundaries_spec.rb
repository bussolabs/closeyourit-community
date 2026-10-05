# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private crash attachments", type: :request do
  # Rack request specs supply in-memory IO; real Puma certification separately verifies tmpfs.
  around do |example|
    previous = Rails.configuration.x.crash_ingestion_enabled
    Rails.configuration.x.crash_ingestion_enabled = true
    example.run
  ensure
    Rails.configuration.x.crash_ingestion_enabled = previous
  end

  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "Crashes", scopes: %w[ingest read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}" } }
  let(:ingest_path) { "/api/#{project.sentry_project_id}/envelope/?sentry_key=#{credential[:token].public_key}" }

  def envelope(bytes: "password=private\nhello", attachment_type: "event.attachment", event_id: "a" * 32)
    event = { event_id: event_id, message: "Crash", release: "v1" }.to_json
    [ { event_id: event_id }.to_json, { type: "event", length: event.bytesize }.to_json, event,
      { type: "attachment", attachment_type: attachment_type, length: bytes.bytesize, filename: "notes.txt" }.to_json, bytes ].join("\n").b
  end

  it "reports disabled attachment ingestion without storing an attachment" do
    Rails.configuration.x.crash_ingestion_enabled = false
    post ingest_path, params: envelope
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.headers.fetch("X-CloseYourIt-Attachment-Results"))).to include("accepted" => 0, "rejected" => 1, "diagnostics" => { "feature_disabled" => 1 })
    expect(project.crash_reports).to be_empty
  end

  it "rejects ambiguous event ownership before storing attachments" do
    event = { event_id: "b" * 32, message: "Other" }.to_json
    body = envelope.sub(/\A[^\n]+/, "{}") + "\n" + { type: "event", length: event.bytesize }.to_json + "\n" + event
    post ingest_path, params: body
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("ambiguous_event_identity")
    expect(project.crash_reports).to be_empty
  end

  it "canonicalizes UUID-shaped crash identities across attachment and event storage" do
    uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    post ingest_path, params: envelope(event_id: uuid)
    expect(response).to have_http_status(:ok)
    expect(project.crash_reports.sole.event_id).to eq("a" * 32)
    expect(Errors::IngestPayload.where(project_id: project.id).sole.payload.fetch("event_id")).to eq("a" * 32)
  end

  it "keeps malformed event identifiers rejected instead of coercing them" do
    post ingest_path, params: envelope(event_id: "invalid")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("missing_event_identity")
    expect(project.crash_reports).to be_empty
  end

  it "rejects a malformed multipart minidump through the public error contract" do
    post "/api/#{project.sentry_project_id}/minidump?sentry_key=#{credential[:token].public_key}", params: "text", headers: { "Content-Type" => "text/plain" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("R422-CRASH-001")
  end

  it "rejects multipart ingest while the feature is disabled" do
    Rails.configuration.x.crash_ingestion_enabled = false
    post "/api/#{project.sentry_project_id}/minidump?sentry_key=#{credential[:token].public_key}", params: "text", headers: { "Content-Type" => "text/plain" }
    expect(response).to have_http_status(:service_unavailable)
  end

  it "uses an existing processed crash report to initialize a matching attachment-only event" do
    proof = JSON.parse(Pathname(__dir__).join("../../fixtures/artifacts/linux-arm64-crash-manifest.json").read).fetch("manifest")
    project.crash_reports.create!(event_id: "a" * 32, manifest: proof)
    body = [ { event_id: "a" * 32 }.to_json, { type: "attachment", filename: "note.txt", length: 5 }.to_json, "hello" ].join("\n")
    post ingest_path, params: body
    expect(response).to have_http_status(:ok)
    staged = Errors::IngestPayload.where(project_id: project.id).sole.payload
    expect(staged).to include("platform" => "native", "level" => "fatal", "message" => "Native crash (symbols unavailable)")
  end
end
