# frozen_string_literal: true

require "rails_helper"

# CYRA-1161 — an SDK asks at start-up whether its version is retired. The public key is enough,
# the answer holds only the state and the message, and a retire reaches the next request at once.
RSpec.describe "Api::V1::ReleaseStatuses", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:issued) do
    Projects::Tokens::Issue.call(project:, name: "Browser", host: "bugs.example.com", environment:).value
  end
  let(:public_key) { issued[:token].public_key }
  let(:owner) { create(:account) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def status_path(version, key: public_key) = "/api/v1/projects/#{project.id}/release_status?version=#{version}&sentry_key=#{key}"

  def create_release(version)
    create(:release, project:, version:, environment: environment.code)
  end

  it "answers retired with the message of a retired version" do
    release = create_release("2.4.1")
    Projects::Releases::Retire.call(release:, message: "Please update: 2.4.1 crashes at start-up", actor: owner)

    get status_path("2.4.1")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => { "retired" => true, "message" => "Please update: 2.4.1 crashes at start-up" })
  end

  it "answers active with no message once the version is restored" do
    release = create_release("2.4.1")
    Projects::Releases::Retire.call(release:, message: "Update", actor: owner)
    Projects::Releases::Restore.call(release:, actor: owner)

    get status_path("2.4.1")

    expect(response.parsed_body).to eq("data" => { "retired" => false, "message" => nil })
  end

  it "answers active, without an error, for a version the project never saw" do
    get status_path("9.9.9")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => { "retired" => false, "message" => nil })
  end

  it "reads the release of the token's environment only" do
    release = create(:release, project:, version: "2.4.1", environment: "elsewhere")
    Projects::Releases::Retire.call(release:, message: "Update", actor: owner)

    get status_path("2.4.1")

    expect(response.parsed_body.dig("data", "retired")).to be(false)
  end

  it "asks for a version" do
    get "/api/v1/projects/#{project.id}/release_status?sentry_key=#{public_key}"

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-RELEASE-002")
  end

  it "tells the browser to check again every time, and answers unchanged when nothing changed" do
    create_release("2.4.1")

    get status_path("2.4.1")
    etag = response.headers["ETag"]

    expect(response.headers["Cache-Control"]).to include("no-cache")
    expect(etag).to be_present

    get status_path("2.4.1"), headers: { "If-None-Match" => etag }

    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
  end

  it "gives the new state to a browser holding a copy, right after a retire" do
    release = create_release("2.4.1")
    get status_path("2.4.1")
    etag = response.headers["ETag"]

    Projects::Releases::Retire.call(release:, message: "Update now", actor: owner)
    get status_path("2.4.1"), headers: { "If-None-Match" => etag }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "retired")).to be(true)
  end

  it "keeps the answer ready instead of reading the database again" do
    create_release("2.4.1")
    get status_path("2.4.1")

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("projects_releases") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get status_path("2.4.1") }

    expect(response).to have_http_status(:ok)
    expect(queries).to be_empty
  end

  it "refuses an unknown key at once, saying nothing about versions" do
    get status_path("2.4.1", key: "0" * 32)

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("retired")
  end

  it "refuses the key of another project" do
    other = create(:project, organization:)
    other_environment = create(:environment, organization:).tap { |e| other.environments << e }
    other_key = Projects::Tokens::Issue.call(project: other, name: "Other", host: "bugs.example.com",
                                             environment: other_environment).value[:token].public_key

    get status_path("2.4.1", key: other_key)

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include("retired")
  end

  it "refuses a browser from a site the project does not allow" do
    project.update!(allowed_origins: [ "https://app.example" ])

    get status_path("2.4.1"), headers: { "HTTP_ORIGIN" => "https://evil.example" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-INGEST-002")
  end
end
