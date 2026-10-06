# frozen_string_literal: true

require_relative "runtime"
Certification::Runtime.boot!
require_relative "../../spec/rails_helper"
require "open3"

processor = URI.parse(ENV.fetch("NATIVE_SYMBOL_PROCESSOR_URL"))
raise "ELF certification requires an owned loopback processor" unless processor.scheme == "http" && %w[127.0.0.1 localhost ::1].include?(processor.host) && processor.userinfo.nil?

RSpec.describe "Real ELF JSON symbol readback", type: :request do
  it "ingests the captured event, uploads its actual ELF and reads resolved frames privately" do
    binary = File.binread(ENV.fetch("ELF_CERTIFICATION_OBJECT"))
    payload = JSON.parse(Rails.root.join("spec/fixtures/artifacts/native-elf-event.json").read)
    image = payload.dig("debug_meta", "images").find { |entry| entry["code_file"] == "native-policy-input" }
    project = create(:project)
    environment = create(:environment, organization: project.organization, code: payload.fetch("environment"), label: "Native policy")
    project.environments << environment
    credential = Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "ELF certification", scopes: %w[ingest read]).value
    read_headers = { "Authorization" => "Bearer #{credential.fetch(:secret)}" }
    event_json = payload.to_json
    envelope = [ { event_id: payload.fetch("event_id") }.to_json, { type: "event", length: event_json.bytesize }.to_json, event_json ].join("\n")
    post "/api/#{project.sentry_project_id}/envelope/?sentry_key=#{credential.fetch(:token).public_key}", params: envelope,
      headers: { "Content-Type" => "application/x-sentry-envelope" }
    expect(response).to have_http_status(:ok)
    staged = Errors::IngestPayload.where(project_id: project.id).sole
    Errors::IngestJob.perform_now(payload_id: staged.id)
    event = project.error_events.sole
    expect(event.event_id).to eq(payload.fetch("event_id"))
    initial = Errors::Symbolication::Resolve.call(event: event)
    expect(initial.fetch("frames").map { |frame| frame["status"] }.uniq).to eq([ "missing_artifact" ])

    account = create(:account)
    create(:membership, account: account, organization: project.organization, role: :owner)
    token = Accounts::ApiTokens::Issue.call(account: account, organization: project.organization, name: "ELF upload").value.fetch(:secret)
    upload = { format: "elf", architecture: "arm64", debug_id: image.fetch("debug_id"), code_id: image.fetch("code_id"), object_base64: Base64.strict_encode64(binary) }
    post "/cli/v1/projects/#{project.id}/artifacts/native_symbols", params: upload.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("data").fetch("sha256")).to eq(Digest::SHA256.hexdigest(binary))
    Errors::SymbolicateJob.perform_now(project_id: project.id, event_id: event.id, event_created_at: event.created_at.iso8601(6))

    path = "/api/v1/error_groups/#{event.group_id}/events"
    get path, headers: read_headers
    expect(response).to have_http_status(:ok)
    result = response.parsed_body.fetch("data").sole.fetch("symbolication")
    expect(result).to include("kind" => "native", "status" => "partial")
    expect(result.fetch("frames").size).to eq(6)
    locations = result.fetch("frames").flat_map { |frame| frame.fetch("locations", []) }
    expect(locations).to include(include("function" => "native_policy_crash_leaf"))
    expect(locations).to include(include("function" => "main"))
    expect(locations).to all(include("line" => be_a(Integer)))
    oracle = ENV.fetch("ELF_CERTIFICATION_ADDR2LINE")
    result.fetch("frames").select { |frame| frame["status"] == "resolved" }.each do |frame|
      output, status = Open3.capture2(oracle, "-f", "-C", "-e", ENV.fetch("ELF_CERTIFICATION_OBJECT"), frame.fetch("lookup_offset"))
      expect(status.success?).to be(true)
      function, position = output.lines.map(&:strip)
      location = frame.fetch("locations").sole
      expect(function).to eq(location.fetch("function"))
      expect(position).to eq("#{location.fetch('file')}:#{location.fetch('line')}")
    end
    get path
    expect(response).to have_http_status(:unauthorized)
    other = create(:project)
    other_environment = create(:environment, organization: other.organization)
    other.environments << other_environment
    other_token = Projects::Tokens::Issue.call(project: other, environment: other_environment, host: "localhost", name: "Other project", scopes: %w[read]).value.fetch(:secret)
    get path, headers: { "Authorization" => "Bearer #{other_token}" }
    expect(response).to have_http_status(:not_found)
    report_path = ENV.fetch("ELF_CERTIFICATION_REPORT")
    File.write(report_path, JSON.pretty_generate({ event_id: event.event_id, binary_sha256: Digest::SHA256.hexdigest(binary), symbolication: result,
      oracle_sha256: Digest::SHA256.file(oracle).hexdigest, oracle_agreement: true,
      android_runtime_verified: false, scope: "Real Linux crash through Rails request stack, private upload and authenticated readback" }) + "\n", mode: "wx")
  ensure
    project&.native_symbol_artifacts&.includes(:blob)&.each { |artifact| artifact.blob.service.delete(artifact.blob.key) }
  end
end
