# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Otlp::Decode do
  def export(*logs)
    { "resourceLogs" => [ { "resource" => { "attributes" => [ { "key" => "service.name", "value" => { "stringValue" => "checkout" } } ] },
      "scopeLogs" => [ { "scope" => { "name" => "logger" }, "logRecords" => logs } ] } ] }
  end

  let(:log) do
    { "timeUnixNano" => "1780000000123456789", "observedTimeUnixNano" => "1780000001123456789",
      "severityNumber" => 18, "severityText" => "ERROR2", "traceId" => "a" * 32, "spanId" => "b" * 16,
      "body" => { "stringValue" => "Failure alice@example.test" } }
  end

  it "preserves exact protocol fields and scrubs free text before durable storage" do
    result = described_class.call(payload: export(log))
    expect(result.rejected).to eq(0)
    snapshot = result.records.sole
    expect(snapshot[:record]).to include("severityNumber" => 18, "severityText" => "ERROR2", "timeUnixNano" => log["timeUnixNano"], "spanId" => "b" * 16)
    expect(snapshot[:record].dig("body", "stringValue")).to eq("Failure [FILTERED]")
    expect(snapshot[:error_event_id]).to be_nil
    expect(snapshot[:exception]).to be(false)
  end

  it "uses only explicit log and cross-channel error identities" do
    log["attributes"] = [ { "key" => "log.record.uid", "value" => { "stringValue" => "producer-event-1" } },
                         { "key" => "closeyourit.error.event_id", "value" => { "stringValue" => "c" * 32 } } ]
    snapshot = described_class.call(payload: export(log)).records.sole
    expect(snapshot).to include(producer_uid: "producer-event-1", error_event_id: "c" * 32, exception: false)
  end

  it "requires an explicit exception event and exception type to create an error" do
    log["eventName"] = "exception"
    expect(described_class.call(payload: export(log)).records.sole[:exception]).to be(false)
    log["attributes"] = [ { "key" => "exception.type", "value" => { "stringValue" => "TypeError" } } ]
    expect(described_class.call(payload: export(log)).records.sole[:exception]).to be(true)
  end
  it "rejects invalid identifiers, severity, opaque bytes and oversized typed attributes per record" do
    invalid = [ log.merge("traceId" => "0" * 32), log.merge("spanId" => "short"), log.merge("severityNumber" => 25),
      log.merge("body" => { "bytesValue" => Base64.strict_encode64("\xff".b) }),
      log.merge("attributes" => Array.new(129) { |index| { "key" => "key#{index}", "value" => {} } }) ]
    result = described_class.call(payload: export(*invalid, log))
    expect(result.rejected).to eq(invalid.size)
    expect(result.records.size).to eq(1)
  end

  it "rejects malformed structures and oversized batches before admission" do
    expect { described_class.call(payload: { "resourceLogs" => "invalid" }) }.to raise_error(described_class::Malformed)
    expect { described_class.call(payload: export(*Array.new(1_001) { log })) }.to raise_error(described_class::Malformed)
  end

  it "preserves structured body types while scrubbing credentials and semantic private keys" do
    item = log.merge("body" => { "kvlistValue" => { "values" => [
      { "key" => "credit_card", "value" => { "stringValue" => "private-card" } },
      { "key" => "note", "value" => { "bytesValue" => Base64.strict_encode64("cyi_" + "x" * 40) } },
      { "key" => "count", "value" => { "intValue" => "9223372036854775807" } }
    ] } })
    body = described_class.call(payload: export(item)).records.sole[:record]["body"]
    expect(body.to_json).not_to include("private-card")
    values = body.fetch("kvlistValue").fetch("values").to_h { |entry| [ entry["key"], entry["value"] ] }
    expect(values["count"]).to eq("intValue" => "9223372036854775807")
    expect(Base64.strict_decode64(values["note"]["bytesValue"])).to eq("[FILTERED]")
  end
  it "accepts an empty batch and both severity endpoints while rejecting an undefined severity" do
    expect(described_class.call(payload: export).records).to eq([])
    result = described_class.call(payload: export(log.merge("severityNumber" => 0), log.merge("severityNumber" => 24), log.merge("severityNumber" => 25)))
    expect(result.records.map { |item| item[:record]["severityNumber"] }).to eq([ 0, 24 ])
    expect(result.rejected).to eq(1)
  end
end
