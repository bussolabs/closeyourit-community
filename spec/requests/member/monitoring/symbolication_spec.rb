# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member error symbolication", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:group) { create(:error_group, project: project) }

  before do
    create(:membership, account: account, organization: project.organization, role: :owner)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def event(platform: "javascript", frames: [ { "filename" => "app.js", "function" => "generated", "lineno" => 1, "colno" => 1 } ])
    create(:error_event, group: group, project: project, release: "v1", payload: { "platform" => platform }, stacktrace: { "frames" => frames })
  end

  it "renders the actual source map result, preserves received evidence and escapes identifiers" do
    occurrence = event
    Artifacts::SourceMaps::Upload.call(project: project, account: account, metadata: { "release" => "v1", "generated_file" => "app.js" },
      map: { "version" => 3, "sources" => [ "<script>source.ts</script>" ], "names" => [], "mappings" => "AAAA" })
    Errors::Symbolication::Record.call(event: occurrence)
    get member_monitoring_error_group_path(group), params: { locale: "en" }
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="derived-stack"]').text).to include("Original function unavailable", "source.ts", "generated")
    expect(html.at_css('[data-test="received-stack"]').text).to include("generated", "app.js")
    expect(html.css("script").map(&:text)).not_to include("source.ts")
    expect(occurrence.reload.stacktrace["frames"].first["filename"]).to eq("app.js")
    expect(html.at_css('[data-test="symbolication-upload-help"]')).to be_present
  end

  it "batch reads multiple occurrences once and keeps pending controls independently addressable" do
    account.update!(locale: "it")
    3.times { event }
    statements = []
    listener = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:sql].include?("bounded_result") }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      get member_monitoring_error_group_path(group), params: { occurrences: "all", locale: "it" }
    end
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(statements.size).to eq(1)
    expect(html.css('[data-test="symbolication"]').size).to eq(3)
    expect(html.css('[data-test="received-stack"]').map { |node| node["id"] }.uniq.size).to eq(3)
    expect(html.text).to include("Ricostruzione in attesa", "Stack ricevuto")
  end

  it "keeps received evidence available when the derived read exceeds its SQL budget" do
    occurrence = event
    Errors::Symbolication.create!(project_id: project.id, event_id: occurrence.id, event_created_at: occurrence.created_at,
      result: { "frames" => [], "large" => "x" * 5.megabytes })
    get member_monitoring_error_group_path(group), params: { locale: "en" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Reconstructed data exceeds the page limit", "generated")
  end

  it "shows every Java alternative and expanded inline line with an explicit ambiguity label" do
    occurrence = event(platform: "java")
    occurrence.update!(payload: occurrence.payload.merge("breadcrumbs" => [ { "message" => "Android activity started", "category" => "navigation" } ]))
    Errors::Symbolication.create!(project_id: project.id, event_id: occurrence.id, event_created_at: occurrence.created_at,
      result: { "kind" => "proguard", "status" => "partial", "groups" => [ { "kind" => "frame", "status" => "ambiguous", "index" => 0,
        "alternatives" => [ { "lines" => [ "at Checkout.first(Checkout.java:1)", "at Checkout.second(Checkout.java:2)" ] }, { "lines" => [ "at Other.call(Other.java:3)" ] } ] } ] })
    get member_monitoring_error_group_path(group), params: { locale: "en" }
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="ambiguous-frame"]').text).to include("2 possible reconstructions")
    expect(html.css('[data-test="reconstructed-lines"]').map(&:text)).to eq([ "at Checkout.first(Checkout.java:1)\nat Checkout.second(Checkout.java:2)", "at Other.call(Other.java:3)" ])
    expect(html.at_css('[data-test="received-stack"]').text).to include("generated")
    expect(html.at_css('[data-test="error-breadcrumbs"]').text).to include("Android activity started")
  end

  it "does not render reconstruction controls for an unrelated Ruby event or empty group" do
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-test="symbolication"')
    event(platform: "ruby")
    get member_monitoring_error_group_path(group)
    expect(response.body).not_to include('data-test="symbolication"')
    expect(response.body).to include('data-test="frames"')
  end

  it "keeps a usable received frame when a Java exception has an unsupported nested shape" do
    occurrence = event(platform: "java", frames: [ 42, { "filename" => "app.java", "function" => "received" } ])
    occurrence.update!(payload: occurrence.payload.merge("exception" => { "values" => [ { "type" => "Outer", "stacktrace" => "invalid" }, { "type" => "Inner", "stacktrace" => { "frames" => [ 42 ] } } ] }))
    Errors::Symbolication.create!(project_id: project.id, event_id: occurrence.id, event_created_at: occurrence.created_at,
      result: { "kind" => "proguard", "status" => "unresolved", "reason" => "unsupported_stack", "groups" => [], "frames" => [] })
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("This stack cannot be reconstructed", "app.java")
  end

  it "allows project readers to view evidence without offering artifact mutations and rejects another project" do
    occurrence = event
    membership = account.memberships.find_by!(organization: project.organization)
    membership.update!(role: :member)
    create(:project_membership, project: project, account: account)
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="received-stack"')
    expect(response.body).not_to include('data-test="symbolication-upload-help"')
    other = create(:error_group)
    get member_monitoring_error_group_path(other)
    expect(response).to have_http_status(:not_found)
    expect(occurrence.reload).to be_present
  end
end
