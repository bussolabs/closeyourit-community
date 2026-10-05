# frozen_string_literal: true

require "rails_helper"

# CYRA-927 — the Observability landing is one table: a row per project, a column per signal, so the
# page says WHERE something is wrong and what is not set up, not only how many. It replaced the cards
# of CYRA-386, which said "9 errors" without saying where.
RSpec.describe "Member — Observability matrix", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, name: "Payments API") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  def row(id) = body.at_css(%([data-test="observability-row-#{id}"]))

  def cell(id, key) = row(id).at_css(%([data-test="observability-cell-#{key}"]))

  it "draws one row per visible project, plus the all-projects row, with a column per signal" do
    project
    create(:project, name: "Someone else's")
    sign_in(owner)

    get member_observability_path

    expect(response).to have_http_status(:ok)
    expect(row(project.id)).to be_present
    expect(row("all")).to be_present
    expect(response.body).not_to include(ERB::Util.html_escape("Someone else's"))
    %w[errors vulnerabilities logs performance].each do |key|
      expect(cell(project.id, key)).to be_present, "missing cell #{key}"
    end
    # No project can record: no column of dashes.
    expect(cell(project.id, "replays")).to be_nil
  end

  it "counts the errors to resolve per project and links to the list filtered on it" do
    create_list(:error_group, 2, project:, status: :unresolved)
    create(:error_group, project:, status: :resolved)
    sign_in(owner)

    get member_observability_path

    errors = cell(project.id, "errors")
    expect(errors.at_css('[data-test="observability-cell-value"]').text.strip).to eq("2")
    expect(errors["href"]).to eq(member_monitoring_error_groups_path(ft: 1, project_id: [ project.id ], status: [ "unresolved" ]))
    expect(cell("all", "errors").at_css('[data-test="observability-cell-value"]').text.strip).to eq("2")
  end

  it "draws the last 24 hours of errors and marks the cell when they grow since yesterday" do
    group = create(:error_group, project:, status: :unresolved)
    create(:error_event, group:, created_at: 30.hours.ago)
    create_list(:error_event, 2, group:, created_at: 2.hours.ago)
    sign_in(owner)

    get member_observability_path

    errors = cell(project.id, "errors")
    expect(errors.at_css("svg[data-test='sparkline']")).to be_present
    expect(errors["data-rising"]).to eq("true")
  end

  it "shows a signal never set up as a dashed cell that leads to setting it up" do
    project
    sign_in(owner)

    get member_observability_path

    logs = cell(project.id, "logs")
    expect(logs["data-state"]).to eq("off")
    expect(logs["href"]).to eq(member_monitoring_log_entries_path)
    expect(cell(project.id, "performance")["data-state"]).to eq("off")
    expect(body.at_css('[data-test="observability-overview-inactive"]')).to be_nil
  end

  it "counts the logs of the last 24 hours once the project has written any" do
    create(:log_entry, project:, created_at: 3.days.ago)
    create(:log_entry, project:, created_at: 1.hour.ago)
    sign_in(owner)

    get member_observability_path

    logs = cell(project.id, "logs")
    expect(logs["data-state"]).to eq("count")
    expect(logs.at_css('[data-test="observability-cell-value"]').text.strip).to eq("1")
  end

  # Recordings exist only on web projects, and only once turned on.
  it "tells a project that cannot record from one that has not turned recording on" do
    web = create(:project, organization:, name: "Storefront")
    web.platforms << create(:platform, organization:, supports_session_replay: true)
    recording = create(:project, organization:, name: "Dashboard")
    recording.platforms << create(:platform, organization:, supports_session_replay: true)
    recording.update!(session_replay_enabled: true)
    Replays::Session.create!(project: recording, replay_session_id: SecureRandom.uuid, started_at: 1.hour.ago)
    project
    sign_in(owner)

    get member_observability_path

    expect(cell(project.id, "replays")["data-state"]).to eq("na")
    expect(cell(web.id, "replays")["data-state"]).to eq("off")
    expect(cell(recording.id, "replays").at_css('[data-test="observability-cell-value"]').text.strip).to eq("1")
  end

  it "puts the projects with the most errors to resolve first, twelve per page" do
    quiet = create(:project, organization:, name: "Zzz quiet")
    create_list(:error_group, 3, project:, status: :unresolved)
    allow_n_plus_one { create_list(:project, 11, organization:) }
    sign_in(owner)

    get member_observability_path

    ids = body.css('[data-test^="observability-row-"]').map { |node| node["data-test"].delete_prefix("observability-row-") }
    expect(ids.first(2)).to eq([ "all", project.id ])
    expect(ids.size).to eq(13)
    expect(ids).not_to include(quiet.id)
    expect(body.at_css('[data-test="observability-pagination"]')).to be_present
  end
end
