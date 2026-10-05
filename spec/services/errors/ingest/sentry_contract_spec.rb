# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sentry admission contract", type: :service do
  def parse(body)
    Errors::Ingest::EnvelopeParser.call(body: body)
  end

  it "uses the envelope event identifier ahead of the body identifier" do
    result = parse("{\"event_id\":\"header-id\"}\n{\"type\":\"event\"}\n{\"event_id\":\"body-id\",\"message\":\"hello\"}\n")
    expect(result.value.sole["event_id"]).to eq("header-id")
  end

  it "retains header-only identifiers for retry deduplication" do
    expect(parse("{\"event_id\":\"header-id\"}\n{\"type\":\"event\"}\n{}\n").value.sole["event_id"]).to eq("header-id")
  end

  it "rejects malformed framing and consumed event shapes without raising" do
    [ "[]\n", "{}\n[]\n{}\n", "{}\n{\"type\":\"event\",\"length\":\"2\"}\n{}\n",
      "{}\n{\"type\":\"event\",\"length\":3}\n{}", "{}\n{\"type\":\"event\",\"length\":2}\n{}junk\n",
      "{}\n{\"type\":\"event\"}\n{\"exception\":{\"values\":[42]}}\n" ].each do |body|
      expect(parse(body)).to be_err
    end
  end

  it "retains binary attachments separately and bounds unknown item diagnostics" do
    parser = Errors::Ingest::EnvelopeParser.new(body: "{}\n{\"type\":\"attachment\",\"length\":3}\n\xFF\nX\n{\"type\":\"untrusted-secret\"}\n{}\n".b)
    expect(parser.call.value).to eq([])
    expect(parser.ignored_counts).to eq("unknown" => 1)
    expect(parser.attachments).to eq([ { header: { "type" => "attachment", "length" => 3 }, bytes: "\xFF\nX".b } ])
  end

  it "reads at most the wire limit plus one byte from an input stream" do
    input = StringIO.new("x" * (Errors::Ingest::EnvelopeParser::MAX_COMPRESSED + 10))
    expect(parse(input).error.status).to eq(:content_too_large)
    expect(input.pos).to eq(Errors::Ingest::EnvelopeParser::MAX_COMPRESSED + 1)
  end

  it "supports logentry while retaining legacy message precedence and grouping" do
    payload = { "logentry" => { "formatted" => "Order 42 failed" } }
    expect(Errors::Ingest::Normalize.call(payload: payload).title).to eq("Order 42 failed")
    expect(Errors::Fingerprint.call(payload: payload)).to eq(Errors::Fingerprint.call(payload: { "message" => "Order 42 failed" }))
    expect(Errors::PayloadFields.call(payload: payload)[:message]).to eq("Order 42 failed")
    expect(Errors::Ingest::Normalize.call(payload: payload.merge("message" => "Legacy")).title).to eq("Legacy")
  end

  it "preserves and scrubs official breadcrumb arrays" do
    payload = { "breadcrumbs" => [ { "message" => "Contact hello@example.test", "data" => { "token" => "private-value" } } ] }
    normalized = Errors::Ingest::Normalize.call(payload: payload)
    expect(normalized.payload["breadcrumbs"]).to be_an(Array)
    expect(normalized.payload["breadcrumbs"].sole).to eq("message" => "Contact [FILTERED]", "data" => { "token" => "[FILTERED]" })
  end

  it "preserves validated trace protocol identifiers without exempting free metadata" do
    trace = { "trace_id" => "a" * 32, "span_id" => "b" * 16, "parent_span_id" => "c" * 16 }
    payload = { "contexts" => { "trace" => trace }, "extra" => { "span_id" => "private-value" } }
    normalized = Errors::Ingest::Normalize.call(payload: payload)
    expect(normalized.payload.dig("contexts", "trace")).to eq(trace)
    expect(normalized.context.dig("contexts", "trace")).to eq(trace)
    expect(normalized.payload.dig("extra", "span_id")).to eq("[FILTERED]")
    expect(Errors::Ingest::Normalize.call(payload: normalized.payload).payload).to eq(normalized.payload)
  end

  it "keeps different root causes apart when the outer exception is identical" do
    first = { "exception" => { "values" => [ { "type" => "TimeoutError" }, { "type" => "WrapperError" } ] } }
    second = { "exception" => { "values" => [ { "type" => "PermissionError" }, { "type" => "WrapperError" } ] } }
    expect(Errors::Fingerprint.call(payload: first)).not_to eq(Errors::Fingerprint.call(payload: second))
  end
end
