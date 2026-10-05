# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member installation guidance", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:run_id) { "9520000000000009" }
  before do
    create(:membership, account: account, organization: project.organization, role: :member)
    create(:project_membership, project: project, account: account)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "renders the selected exact observation and keeps unfamiliar versions unobserved" do
    get member_guides_installation_path, params: { project_id: project.id, run_id: run_id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-installation-run-id="9520000000000009"', 'data-installation-version="2.71.0"')
    get member_guides_installation_path, params: { project_id: project.id, run_id: run_id, version: "99.0.0" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="installation-unobserved"')
    expect(response.body).not_to include('data-test="installation-setup"')
  end

  it "looks up receipt metadata with view access and rejects a hidden project" do
    event = create(:error_event, group: create(:error_group, project: project), project: project, event_id: "a" * 32, environment: "test", release: "build1")
    query = { project_id: project.id, run_id: run_id, event_id: event.event_id, environment: "test", release: "build1" }
    get member_guides_installation_receipt_path, params: query
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include("state" => "received", "received_at" => event.created_at.utc.iso8601(6))
    hidden = create(:project, organization: project.organization)
    get member_guides_installation_receipt_path, params: query.merge(project_id: hidden.id), headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("application/json")
    expect(response.body.bytesize).to be <= Guides::Installation::Receipt::MAX_RESPONSE_BYTES
    expect(response.parsed_body).to eq("error" => { "code" => "installation_not_found", "message" => I18n.t("member.installation.not_found") })
    expect(response.body).not_to include(hidden.id, "Projects::Project", "ActiveRecord")
    get member_guides_installation_path, params: { project_id: hidden.id, run_id: run_id }
    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("text/html")
  end
  it "never reveals a public key to a reader and selects only an active ingest token for a manager" do
    readonly = create(:project_token, :read_only, project: project)
    expired = create(:project_token, :expired, project: project)
    revoked = create(:project_token, :revoked, project: project)
    active = create(:project_token, :ingest_only, project: project)
    query = { project_id: project.id, run_id: run_id }
    get member_guides_installation_path, params: query
    expect(response).to have_http_status(:ok)
    [ readonly, expired, revoked, active ].each { |token| expect(response.body).not_to include(token.public_key, token.token_digest) }
    Authorization::SetAccountPermissions.call(organization: project.organization, account: account, allow_keys: [ "tokens.manage" ])
    get member_guides_installation_path, params: query
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(active.public_key, active.to_sentry_dsn(host: "www.example.com"))
    [ readonly, expired, revoked ].each { |token| expect(response.body).not_to include(token.public_key) }
    expect(response.body).not_to include(active.token_digest)
    get member_guides_installation_path, params: query.merge(environment: "unknown-environment")
    expect(response.body).not_to include(active.public_key)
    get member_guides_installation_path, params: query.merge(run_id: "9820000000000001")
    expect(response.body).not_to include(active.public_key)
    active.update!(revoked_at: Time.current)
    get member_guides_installation_path, params: query
    expect(response.body).not_to include(active.public_key)
  end

  JSON.parse(Rails.root.join("config/installation_catalog/observations.json").read).fetch("observations").each do |record|
    it "renders the exact #{record.fetch("run_id")} recipe without promoting claims" do
      get member_guides_installation_path, params: { project_id: project.id, run_id: record.fetch("run_id") }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-installation-run-id=\"#{record['run_id']}\"", 'data-test="installation-setup"')
      expect(response.body).not_to include("Translation missing")
      if record.dig("tuple", "integration").start_with?("php-laravel")
        expect(response.body).to include("Runtime::start", "shasum", "repositories.closeyourit")
      end
    end
  end

  it "rejects missing or unknown observations and shows catalog failures as unavailable" do
    get member_guides_installation_receipt_path, params: { project_id: project.id }
    expect(response).to have_http_status(:unprocessable_content)
    get member_guides_installation_path, params: { project_id: project.id, run_id: "unknown" }
    expect(response).to have_http_status(:unprocessable_content)
    allow(Guides::Installation::Catalog).to receive(:call).and_raise(Guides::Installation::Unavailable)
    get member_guides_installation_path
    expect(response).to have_http_status(:service_unavailable)
    get member_guides_installation_receipt_path, params: { project_id: project.id, run_id: run_id }
    expect(response).to have_http_status(:service_unavailable)
  end

  it "keeps an empty visible project set read-only and exposes the guide through navigation" do
    project.project_memberships.where(account: account).destroy_all
    get member_guides_installation_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="installation-no-projects"')
    expect(response.body).not_to include('data-test="installation-receipt-check"')
    expect(response.body).to include('data-test="member-guides-card-installation"')
  end
  it "finds visible projects beyond the bounded selector without exposing a matching hidden project" do
    stub_const("Member::Guides::InstallationController::PROJECT_LIMIT", 2)
    project.update!(name: "First")
    middle = create(:project, organization: project.organization, name: "Middle")
    target = create(:project, organization: project.organization, name: "Zebra installation")
    [ middle, target ].each { |item| create(:project_membership, project: item, account: account) }
    hidden = create(:project, organization: project.organization, name: "Zebra hidden")
    get member_guides_installation_path, params: { run_id: run_id }
    expect(response.body).not_to include(target.id, hidden.id)
    get member_guides_installation_path, params: { run_id: run_id, project_query: "Zebra" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(target.id)
    expect(response.body).not_to include(hidden.id)
    get member_guides_installation_path, params: { run_id: run_id, project_query: target.key }
    expect(response.body).to include(target.id)
    get member_guides_installation_path, params: { run_id: run_id, project_query: "No such project" }
    expect(response.body).to include(I18n.t("member.installation.no_matching_projects"))
    expect(response.body).not_to include('data-test="installation-receipt-check"')
  end

  %i[project_query project_id].each do |key|
    [ [ "value" ], { "nested" => "value" } ].each do |invalid|
      it "rejects a #{invalid.class} #{key} parameter with 422" do
        get member_guides_installation_path, params: { run_id: run_id, project_id: project.id, key => invalid }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  [ nil, "", [ "value" ], { "nested" => "value" } ].each do |invalid|
    it "requires a nonempty scalar receipt project for #{invalid.inspect}" do
      get member_guides_installation_receipt_path, params: { run_id: run_id, project_id: invalid,
        event_id: "a" * 32, environment: "test", release: "build1" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("installation_invalid")
    end
  end
end
