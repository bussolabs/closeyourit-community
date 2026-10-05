# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private source map artifacts", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:token) { Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "Artifacts").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }
  let(:path) { "/cli/v1/projects/#{project.id}/artifacts/source_maps" }
  let(:payload) { { release: "v1", generated_file: "https://example.test/app.js", source_map: { version: 3, sources: [ "source.ts" ], names: [], mappings: "AAAA", sourcesContent: [ "private source" ] } } }

  before { create(:membership, account: account, organization: organization, role: :owner) }

  it "uploads, lists and reads only private metadata with standard wrappers" do
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:created)
    id = response.parsed_body.fetch("data").fetch("id")
    expect(response.body).not_to include("sourcesContent", "private source", "artifacts/")
    post path, params: payload.merge(generated_file: "https://example.test/other.js").to_json, headers: headers
    get path, headers: headers
    expect(response.parsed_body.fetch("data").size).to eq(2)
    expect(response.parsed_body).to have_key("meta")
    get "#{path}/#{id}", headers: headers
    expect(response.parsed_body.fetch("data")).to include("release" => "v1", "kind" => "source_map")
    get "#{path}/#{id}"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns duplicates without mutation and rejects conflicting immutable identities" do
    post path, params: payload.to_json, headers: headers
    id = response.parsed_body.fetch("data").fetch("id")
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").fetch("id")).to eq(id)
    payload[:source_map][:mappings] = "AACA"
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:conflict)
  end

  it "requires explicit delete confirmation and cannot resolve another project's artifact" do
    post path, params: payload.to_json, headers: headers
    id = response.parsed_body.fetch("data").fetch("id")
    other = create(:project, organization: organization)
    get "/cli/v1/projects/#{other.id}/artifacts/source_maps/#{id}", headers: headers
    expect(response).to have_http_status(:not_found)
    delete "#{path}/#{id}", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    delete "#{path}/#{id}", params: { confirm: true }.to_json, headers: headers
    expect(response).to have_http_status(:no_content)
    get "#{path}/#{id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  [ "", ".json" ].each do |format|
    it "bounds the raw JSON read before framework parameter parsing with format #{format.inspect}" do
      input = Class.new(StringIO) do
        attr_reader :reads
        def read(*args)
          (@reads ||= []) << args.first
          super
        end
      end.new("x" * (Artifacts::MAX_REQUEST + 1))
      env = Rack::MockRequest.env_for("#{path}#{format}", method: "POST", input: input, "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => headers["Authorization"], "HTTP_HOST" => "localhost")
      status, _headers, body = Rails.application.call(env)
      expect(status).to eq(413)
      expect(input.reads).to eq([ Artifacts::MAX_REQUEST + 1 ])
      body.close if body.respond_to?(:close)
    end
  end
  it "allows visible-project readers while forbidding writes and invisible-project lookup" do
    post path, params: payload.to_json, headers: headers
    id = response.parsed_body.fetch("data").fetch("id")
    member = create(:account)
    create(:membership, account: member, organization: organization, role: :member)
    create(:project_membership, account: member, project: project)
    bearer = Accounts::ApiTokens::Issue.call(account: member, organization: organization, name: "Reader").value[:secret]
    scoped_headers = headers.merge("Authorization" => "Bearer #{bearer}")
    get "#{path}/#{id}", headers: scoped_headers
    expect(response).to have_http_status(:ok)
    post path, params: payload.to_json, headers: scoped_headers
    expect(response).to have_http_status(:forbidden)
    delete "#{path}/#{id}", params: { confirm: true }.to_json, headers: scoped_headers
    expect(response).to have_http_status(:forbidden)
    other = create(:project, organization: organization)
    get "/cli/v1/projects/#{other.id}/artifacts/source_maps/#{id}", headers: scoped_headers
    expect(response).to have_http_status(:not_found)
  end

  it "returns additive symbolication for multiple events and immediately invalidates deleted artifacts" do
    map_event = { "release" => "v1", "platform" => "javascript", "exception" => { "values" => [ { "type" => "Error", "value" => "failure", "stacktrace" => { "frames" => [ { "filename" => payload[:generated_file], "lineno" => 1, "colno" => 1, "function" => "minified" } ] } } ] } }
    # Independent worker executions prepare fixtures; only the HTTP batch read is measured.
    events = allow_n_plus_one do
      2.times.map { |index| Errors::Ingest::Record.call(project: project, payload: map_event.merge("event_id" => index.to_s * 32)).value }
    end
    post path, params: payload.to_json, headers: headers
    artifact_id = response.parsed_body.fetch("data").fetch("id")
    allow_n_plus_one { events.each { |event| Errors::Symbolication::Record.call(event: event) } }
    environment = create(:environment, organization: organization)
    project.environments << environment
    secret = Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "Read", scopes: [ "read" ]).value[:secret]
    read_headers = { "Authorization" => "Bearer #{secret}" }
    event_path = "/api/v1/error_groups/#{events.first.group_id}/events"
    get event_path, headers: read_headers
    expect(response).to have_http_status(:ok)
    rows = response.parsed_body.fetch("data")
    expect(rows.size).to eq(2)
    expect(rows.map { |row| row.dig("symbolication", "status") }).to eq(%w[resolved resolved])
    expect(rows.map { |row| row.dig("stacktrace", "frames", 0, "function") }).to eq(%w[minified minified])
    delete "#{path}/#{artifact_id}", params: { confirm: true }.to_json, headers: headers
    get event_path, headers: read_headers
    expect(response.parsed_body.fetch("data").map { |row| row.dig("symbolication", "reason") }).to eq(%w[artifact_deleted artifact_deleted])
  end
end
