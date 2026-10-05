# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member trace inspection", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: project.organization, role: :member)
    create(:project_membership, project: project, account: account)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def admit(owner = project)
    span = { "traceId" => "a" * 32, "spanId" => "b" * 16, "name" => "checkout", "startTimeUnixNano" => "1780000000000000001", "endTimeUnixNano" => "1780000000000000002" }
    Traces::Ingest::Record.call(project: owner, payload: { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => [ span ] } ] } ] })
    owner.traces.sole
  end

  it "renders an honest empty state and received data without inferring complete success" do
    get member_monitoring_traces_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="traces-empty"')
    trace = admit
    get member_monitoring_traces_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(trace.trace_id)
    get member_monitoring_trace_path(trace)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="trace-waterfall"]').text).to include("0.000001 ms")
    expect(html.at_css('[data-test="trace-topology"]').text).to match(/unknown|sconosciuta/i)
    expect(html.at_css('[data-test="trace-selected-span"]').text).to include("b" * 16)
    expect(html.css('[data-test="trace-related-record"]')).to be_empty
    expect(response.body.bytesize).to be < 1.megabyte
  end

  it "keeps same external identities in hidden projects inaccessible" do
    own = admit
    foreign = admit(create(:project, organization: project.organization))
    get member_monitoring_traces_path, params: { project_id: foreign.project_id }
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('[data-test="trace-row"]')).to be_empty
    get member_monitoring_trace_path(foreign)
    expect(response).to have_http_status(:not_found)
    get member_monitoring_trace_path(own), params: { span_id: "c" * 16 }
    expect(response).to have_http_status(:not_found)
  end

  it "abbreviates the breadcrumb while keeping the complete trace identity accessible" do
    trace = admit
    get member_monitoring_trace_path(trace)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    crumb = html.at_css('[data-test="trace-breadcrumb-id"]')
    expect(crumb.text).to eq("aaaaaaaa…aaaa")
    expect(crumb["aria-label"]).to eq(trace.trace_id)
    expect(crumb["title"]).to eq(trace.trace_id)
    expect(html.css("span.break-all").map(&:text)).to include(trace.trace_id)
  end

  it "withholds oversized evidence without turning a valid short page into hidden megabytes" do
    trace = admit
    project.trace_spans.update_all(payload: { "large" => "x" * 100.kilobytes })
    get member_monitoring_trace_path(trace)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="trace-evidence-budget"')
    expect(response.body).not_to include("x" * 1000)
    expect(response.body.bytesize).to be < 1.megabyte
  end

  it "keeps a trace with no retained spans unknown even with an empty search field" do
    trace = admit
    project.trace_spans.delete_all
    get member_monitoring_traces_path, params: { q: "" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(trace.trace_id)
  end

  it "rehydrates saved empty semantic filters as active chips and marks only semantic fields as exact" do
    saved = create(:saved_view, account: account, organization: project.organization, resource_type: "traces", filters: { "environment" => "" })
    get member_monitoring_traces_path, params: saved.reload.filters
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="filter-chip-environment"]').key?("hidden")).to be(false)
    expect(html.at_css('input[name="environment"]').key?("data-filter-bar-exact")).to be(true)
    expect(html.at_css('input[name="environment"]').key?("disabled")).to be(false)
    expect(html.at_css('input[name="service"]').key?("disabled")).to be(true)
    expect(html.at_css('input[name="min_duration_ms"]').key?("data-filter-bar-exact")).to be(false)
  end

  it "explains unknown completeness and retained evidence in the trace guide" do
    get member_guides_traces_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="member-guide-traces"')
    expect(response.body).to include("64 KiB")
  end

  it "finds a visible project beyond the bounded initial options without exposing hidden projects" do
    allow_n_plus_one do
      201.times do |index|
        extra = create(:project, organization: project.organization, name: "A project #{index}")
        create(:project_membership, project: extra, account: account)
      end
      project.update!(name: "ZZ exact destination")
    end
    get member_monitoring_traces_path, params: { project_query: "ZZ exact" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ZZ exact destination")
    expect(response.body).not_to include("A project 0")
  end

  [ { project_id: [ "invalid" ] }, { project_query: { x: "y" } }, { q: { x: "y" } }, { min_duration_ms: "-1" }, { range: "custom", from: "bad" } ].each do |parameters|
    it "returns a bounded validation response for #{parameters.keys.first}" do
      get member_monitoring_traces_path, params: parameters
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="traces-query-error"')
    end
  end
end
