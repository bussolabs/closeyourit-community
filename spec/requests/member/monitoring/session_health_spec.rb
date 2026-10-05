# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member session health", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: project.organization, role: :owner)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def record(status, release: "v1", environment: "production", target: project, started: 1.hour.ago)
    payload = { "sid" => SecureRandom.uuid, "started" => started.iso8601, "timestamp" => Time.current.iso8601,
      "status" => status, "attrs" => { "release" => release, "environment" => environment } }
    items = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
    SessionHealth::Ingest::Record.call(project: target, items: items)
  end

  def aggregate
    payload = { "attrs" => { "release" => "v1", "environment" => "production" },
      "aggregates" => [ { "started" => 1.hour.ago.beginning_of_minute.iso8601, "exited" => 3, "crashed" => 1 } ] }
    items = SessionHealth::Ingest::Decode.call(type: "sessions", payload: payload).map { |value| { type: "sessions", value: value } }
    SessionHealth::Ingest::Record.call(project: project, items: items)
  end

  def visit(**filters)
    get member_monitoring_session_health_path, params: filters
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  it "shows separate source denominators, unknown outcomes and the cohort count" do
    record("exited")
    record("crashed")
    record("ok")
    aggregate
    html = visit
    rows = html.css('[data-test="session-health-row"]')
    expect(rows.size).to eq(2)
    expect(rows.find { |row| row.text.include?("Individual sessions") }.text).to include("50.0%", "1 / 2")
    expect(rows.find { |row| row.text.include?("Aggregated requests") }.text).to include("75.0%", "3 / 4")
    expect(html.at_css('[data-test="session-health-total"]').text).to include("2", "groups")
    expect(html.at_css('[data-test="session-health-definition"]').text).to include("Open and abnormal", "not recordings")
    expect(html.at_css('[data-test="member-nav-session-health"]')).to be_present
  end

  it "keeps an unknown-only denominator unavailable and renders Italian labels" do
    account.update!(locale: "it")
    record("ok")
    html = visit
    row = html.at_css('[data-test="session-health-row"]')
    expect(row.text).to include("Sessioni singole", "0 / 0", "—")
    expect(row.text).not_to include("100%", "0.0%")
    expect(html.at_css("h1").text).to eq("Sessioni")
  end

  it "distinguishes an empty product from an empty filtered result" do
    expect(visit.at_css('[data-test="session-health-empty"]')).to be_present
    record("exited")
    html = visit(q: "absent")
    expect(html.at_css('[data-test="session-health-no-match"]')).to be_present
    expect(html.at_css('[data-test="session-health-toolbar"]')).to be_present
    expect(html.at_css('[data-test="session-health-reset"]')).to be_present
  end

  it "filters literal release text, environments and sources inside the selected period" do
    record("exited", release: "v_1", environment: "staging")
    record("crashed", release: "vx1", environment: "staging")
    record("crashed", release: "v_1", environment: "staging", started: 9.days.ago)
    aggregate
    html = visit(q: "v_", environment: [ "staging" ], source: "individual", range: "7d")
    rows = html.css('[data-test="session-health-row"]')
    expect(rows.size).to eq(1)
    expect(rows.sole.text).to include("v_1", "100.0%", "1 / 1")
    expect(rows.sole.text).not_to include("vx1")
  end

  it "scopes rows and facets to visible projects even with an explicit foreign project filter" do
    record("exited")
    hidden = create(:project, organization: project.organization, name: "Hidden project")
    record("crashed", target: hidden, release: "hidden-release", environment: "hidden-environment")
    record("crashed", target: create(:project), release: "foreign-org")
    account.memberships.find_by!(organization: project.organization).update!(role: :member)
    create(:project_membership, project: project, account: account)
    html = visit
    expect(html.css('[data-test="session-health-row"]').size).to eq(1)
    expect(html.text).not_to include("Hidden project", "hidden-release", "hidden-environment", "foreign-org")
    expect(visit(project_id: hidden.id).css('[data-test="session-health-row"]')).to be_empty
  end

  it "sorts all groups before pagination and keeps unknown percentages last" do
    # Independent ingestion calls prepare fixtures; the page itself remains under the N+1 guard.
    allow_n_plus_one do
      13.times { |index| record("exited", release: format("v%02d", index)) }
      record("ok", release: "unknown")
    end
    html = visit(sort: "-release", per: "12")
    expect(html.css('[data-test="session-health-row"]').size).to eq(12)
    expect(html.css('[data-test="session-health-row"]').first.text).to include("v12")
    expect(visit(sort: "rate", per: "12", page: "2").css('[data-test="session-health-row"]').last.text).to include("unknown")
  end

  it "retains selected authorized facets beyond the initial suggestion window" do
    stub_const("Member::Monitoring::SessionHealthController::FACET_LIMIT", 2)
    record("exited", environment: "alpha")
    record("exited", environment: "beta")
    selected = create(:project, organization: project.organization, name: "Z selected")
    create(:project, organization: project.organization, name: "A earlier")
    record("exited", target: selected, environment: "z-selected")
    html = visit(project_id: selected.id, environment: "z-selected")
    expect(html.css('[data-test="session-health-row"]').size).to eq(1)
    expect(html.at_css('[data-test="filter-project"]').text).to include("Z selected")
    expect(html.at_css('[data-test="filter-environment"]').text).to include("z-selected")
  end

  it "does not expose session cohorts without authentication" do
    delete logout_path
    get member_monitoring_session_health_path
    expect(response).to have_http_status(:redirect)
  end
end
