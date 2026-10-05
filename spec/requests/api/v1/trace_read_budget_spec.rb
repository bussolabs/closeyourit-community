# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private trace read budgets", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project:, environment:, host: "localhost", name: "Read budget", scopes: %w[read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}" } }
  let(:path) { "/api/v1/traces/#{'a' * 32}/spans" }

  def persist_spans(count:, name_size:)
    spans = count.times.map do |index|
      { "traceId" => "a" * 32, "spanId" => (index + 1).to_s(16).rjust(16, "0"), "name" => "x" * name_size,
        "startTimeUnixNano" => "1780000000123456789", "endTimeUnixNano" => "1780000000123456799" }
    end
    payload = { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => spans } ] } ] }
    expect(Traces::Ingest::Record.call(project:, payload:).rejected).to eq(0)
  end

  it "rejects a single response above one MiB without truncating the stored span" do
    persist_spans(count: 1, name_size: 600_000)
    get path, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-OTLP-001")
    expect(response.body.bytesize).to be < 1024
    expect(project.trace_spans.sole.name.bytesize).to eq(600_000)
  end

  it "checks SQL byte sizes before instantiating an oversized page" do
    persist_spans(count: 5, name_size: 600_000)
    hydrated = 0
    observer = ->(_name, _start, _finish, _id, data) { hydrated += data[:record_count] if data[:class_name] == "Traces::Span" }
    ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") { get path, headers: headers }
    expect(response).to have_http_status(:unprocessable_content)
    expect(hydrated).to eq(0)
  end

  it "allows a smaller page without silently dropping records or changing totals" do
    persist_spans(count: 2, name_size: 300_000)
    get path, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    get path, headers: headers, params: { per: 1, page: 2 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole.fetch("span_id")).to eq("0000000000000002")
    expect(response.parsed_body.fetch("meta")).to include("total" => 2, "total_pages" => 2, "page" => 2)
    expect(response.body.bytesize).to be <= 1024 * 1024
  end

  it "accepts the exact encoded response budget and rejects one byte less" do
    persist_spans(count: 1, name_size: 32)
    get path, headers: headers
    size = response.body.bytesize
    stub_const("OtlpReadBudget::MAX_RESPONSE_BYTES", size)
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(size)
    stub_const("OtlpReadBudget::MAX_RESPONSE_BYTES", size - 1)
    get path, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "hydrates only measured identities when a concurrent arrival changes the page offset" do
    persist_spans(count: 2, name_size: 32)
    inserted = false
    observer = lambda do |_name, _start, _finish, _id, data|
      next if inserted || !data[:sql].include?("octet_length(to_jsonb")

      inserted = true
      span = { "traceId" => "a" * 32, "spanId" => "f" * 16, "name" => "arrived during read",
               "startTimeUnixNano" => "1", "endTimeUnixNano" => "2" }
      Traces::Ingest::Record.call(project:, payload: { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => [ span ] } ] } ] })
    end
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      get path, headers: headers, params: { page: 2, per: 1 }
    end
    expect(inserted).to be(true)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole.fetch("span_id")).to eq("0000000000000002")
  end
end
