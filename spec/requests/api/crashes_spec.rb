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

  def envelope(bytes: "password=private\nhello", attachment_type: "event.attachment")
    event = { event_id: "a" * 32, message: "Crash", release: "v1" }.to_json
    [ { event_id: "a" * 32 }.to_json, { type: "event", length: event.bytesize }.to_json, event,
      { type: "attachment", attachment_type: attachment_type, length: bytes.bytesize, filename: "notes.txt" }.to_json, bytes ].join("\n").b
  end

  it "preserves binary framing, rejects opaque content independently and never authorizes raw fallback" do
    post ingest_path, params: envelope(bytes: "\xff\n\x00".b), headers: { "Content-Type" => "application/x-sentry-envelope" }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.headers["X-CloseYourIt-Attachment-Results"])).to include("rejected" => 1)
    expect(Errors::IngestPayload.where(project_id: project.id).count).to eq(1)
  end

  it "stores scrubbed text and serves it only through scoped private endpoints" do
    post ingest_path, params: envelope, headers: { "Content-Type" => "application/x-sentry-envelope" }
    expect(response).to have_http_status(:ok)
    expect(project.crash_reports.count).to eq(1)
    get "/api/v1/crashes/reports", headers: headers
    row = response.parsed_body.fetch("data").sole
    expect(row).to include("event_id" => "a" * 32, "release" => "v1")
    path = row.fetch("attachments").sole.fetch("download_path")
    get path
    expect(response).to have_http_status(:unauthorized)
    get path, headers: headers
    expect(response.body).to eq("password=[FILTERED]\nhello")
    expect(response.headers["Content-Disposition"]).to start_with("attachment;")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  it "requires both scopes for deletion and never resolves another project's report" do
    post ingest_path, params: envelope
    report = project.crash_reports.sole
    other = create(:project)
    other_report = Crashes::Report.create!(project: other, event_id: "b" * 32)
    get "/api/v1/crashes/reports/#{other_report.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    credential[:token].update!(scopes: %w[read])
    delete "/api/v1/crashes/reports/#{report.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
    credential[:token].update!(scopes: %w[read ingest])
    delete "/api/v1/crashes/reports/#{report.id}", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "rejects truncated framing before staging any event or object" do
    post ingest_path, params: envelope.delete_suffix("hello")
    expect(response).to have_http_status(:unprocessable_content)
    expect(project.crash_reports.count).to eq(0)
    expect(Errors::IngestPayload.where(project_id: project.id).count).to eq(0)
  end

  it "fails closed without a processor and never sends native memory to durable staging" do
    bytes = "MDMP" + "\0" * 32
    post ingest_path, params: envelope(bytes: bytes, attachment_type: "event.minidump")
    expect(response).to have_http_status(:service_unavailable)
    expect(project.crash_reports.count).to eq(0)
    expect(Errors::IngestPayload.where(project_id: project.id).count).to eq(0)
  end

  it "canonicalizes uppercase event identities across staging, worker and read-back" do
    post ingest_path, params: envelope.gsub("a" * 32, "A" * 32)
    staged = Errors::IngestPayload.where(project_id: project.id).sole
    expect(staged.payload.fetch("event_id")).to eq("a" * 32)
    Errors::IngestJob.perform_now(payload_id: staged.id)
    get "/api/v1/crashes/reports", headers: headers
    expect(response.parsed_body.fetch("data").sole.fetch("event_id")).to eq("a" * 32)
    expect(project.error_events.sole.event_id).to eq("a" * 32)
  end

  it "forbids deletion with an ingest-only bearer" do
    post ingest_path, params: envelope
    report = project.crash_reports.sole
    credential[:token].update!(scopes: [ "ingest" ])
    delete "/api/v1/crashes/reports/#{report.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "returns multiple reports without per-report queries and hides removed events immediately" do
    post ingest_path, params: envelope
    post ingest_path, params: envelope.gsub("a" * 32, "b" * 32)
    get "/api/v1/crashes/reports", headers: headers
    expect(response.parsed_body.fetch("data").size).to eq(2)
    report = project.crash_reports.find_by!(event_id: "a" * 32)
    Errors::IngestPayload.where(project_id: project.id).delete_all
    get "/api/v1/crashes/reports/#{report.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "bounds raw multipart reads before Rack can create any temporary upload" do
    input = Class.new(StringIO) do
      attr_reader :reads
      def read(*args)
        (@reads ||= []) << args.first
        super
      end
    end.new("x" * (::Crashes::MAX_WIRE + 1))
    path = "/api/#{project.sentry_project_id}/minidump/?sentry_key=#{credential[:token].public_key}"
    env = Rack::MockRequest.env_for(path, method: "POST", input: input, "CONTENT_TYPE" => "multipart/form-data; boundary=boundary", "HTTP_HOST" => "localhost")
    status, _headers, body = Rails.application.call(env)
    expect(status).to eq(413)
    expect(input.reads).to eq([ ::Crashes::MAX_WIRE + 1 ])
    body.close if body.respond_to?(:close)
  end

  it "applies native backpressure before reading multipart bytes" do
    2.times { ::Crashes::REQUEST_SLOTS.push(true, true) }
    path = "/api/#{project.sentry_project_id}/minidump/?sentry_key=#{credential[:token].public_key}"
    post path, params: "unread", headers: { "Content-Type" => "multipart/form-data; boundary=boundary" }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("1")
  ensure
    2.times { ::Crashes::REQUEST_SLOTS.pop(true) }
  end
end
