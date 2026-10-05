# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Ingest::Decode do
  let(:span) do
    { "traceId" => "A" * 32, "spanId" => "B" * 16, "name" => "checkout",
      "startTimeUnixNano" => "1780000000123456789", "endTimeUnixNano" => "1780000000123456799" }
  end

  def decode(*items, resource: {}, scope: {})
    described_class.call(payload: { "resourceSpans" => [ { "resource" => resource, "scopeSpans" => [ { "scope" => scope, "spans" => items } ] } ] })
  end

  it "preserves typed values, flags, status, ordered events, links and dropped counts" do
    span.merge!("flags" => 0xFFFF_FFFF, "status" => { "code" => 2, "message" => "failed" }, "droppedLinksCount" => 7,
      "attributes" => [ { "key" => "amount", "value" => { "intValue" => "9223372036854775807" } },
                        { "key" => "ratio", "value" => { "doubleValue" => 1.25 } },
                        { "key" => "sampled", "value" => { "boolValue" => true } } ],
      "events" => [ { "name" => "second", "timeUnixNano" => "1" }, { "name" => "first", "timeUnixNano" => "0" } ],
      "links" => [ { "traceId" => "c" * 32, "spanId" => "d" * 16, "flags" => 256 } ])
    result = decode(span).spans.sole[:payload]
    expect(result).to include("traceId" => "a" * 32, "spanId" => "b" * 16, "flags" => 0xFFFF_FFFF, "droppedLinksCount" => 7)
    expect(result["events"].pluck("name")).to eq(%w[second first])
    expect(result["attributes"].first.dig("value", "intValue")).to eq("9223372036854775807")
    expect(result.dig("links", 0, "flags")).to eq(256)
  end

  it "scrubs semantic attribute keys and all free text without damaging protocol IDs" do
    token = "cyi_" + "q" * 40
    span["name"] = "request #{token} alice@example.test https://person:password@example.test/path?secret=hidden"
    span["attributes"] = [ { "key" => "db.query.text", "value" => { "stringValue" => "select secret" } },
                           { "key" => "span.id", "value" => { "stringValue" => "b" * 16 } },
                           { "key" => "nested", "value" => { "kvlistValue" => { "values" => [ { "key" => "user.email", "value" => { "stringValue" => "private" } } ] } } } ]
    result = decode(span, resource: { "attributes" => [ { "key" => "authorization", "value" => { "stringValue" => "private" } } ] })
    text = result.spans.to_json
    expect(text).not_to include(token, "alice@example.test", "person:", "password", "?secret", "select secret", "private")
    expect(result.spans.sole[:payload]["spanId"]).to eq("b" * 16)
    expect(text).to include("https://example.test/path", "[FILTERED]")
  end

  it "rejects affected spans for attribute count, key, byte and depth budgets" do
    [ Array.new(129) { |i| { "key" => "key#{i}", "value" => { "intValue" => "1" } } },
      [ { "key" => "x" * 257, "value" => { "intValue" => "1" } } ],
      [ { "key" => "text", "value" => { "stringValue" => "x" * 65_536 } } ] ].each do |attrs|
      expect(decode(span.merge("attributes" => attrs)).rejected).to eq(1)
    end
    value = { "stringValue" => "leaf" }
    9.times { value = { "arrayValue" => { "values" => [ value ] } } }
    expect(decode(span.merge("attributes" => [ { "key" => "deep", "value" => value } ])).rejected).to eq(1)
  end

  it "rejects invalid IDs, timestamps, enum names and duplicate attribute keys" do
    [ { "traceId" => "0" * 32 }, { "spanId" => "short" }, { "parentSpanId" => "B" * 16 },
      { "startTimeUnixNano" => "0" }, { "endTimeUnixNano" => "1" }, { "kind" => "SPAN_KIND_SERVER" },
      { "flags" => -1 }, { "startTimeUnixNano" => 1.5 }, { "endTimeUnixNano" => (2**64).to_s },
      { "attributes" => [ { "key" => "same", "value" => {} }, { "key" => "same", "value" => {} } ] } ].each do |invalid|
      expect(decode(span.merge(invalid)).rejected).to eq(1)
    end
  end

  it "accepts empty batches, ignores unknown fields and rejects structurally malformed requests" do
    expect(decode.rejected).to eq(0)
    expect(decode(span.merge("futureExtension" => "unused")).spans.sole[:payload]).not_to have_key("futureExtension")
    expect { described_class.call(payload: { "resourceSpans" => "invalid" }) }.to raise_error(described_class::Malformed)
    expect { decode(*Array.new(1001, span)) }.to raise_error(described_class::Malformed)
  end

  it "retains nonresolvable links only when they carry attributes or trace state" do
    link = { "traceId" => "0" * 32, "spanId" => "0" * 16, "traceState" => "vendor=value" }
    expect(decode(span.merge("links" => [ link ])).spans.sole[:payload].dig("links", 0, "traceId")).to eq("")
    expect(decode(span.merge("links" => [ link.except("traceState") ])).rejected).to eq(1)
  end

  it "scrubs encoded UTF-8 bytes and canonical sensitive attributes, rejecting opaque bytes and NUL" do
    token = "cyi_" + "s" * 40
    span["attributes"] = [ { "key" => "note", "value" => { "bytesValue" => Base64.strict_encode64(token) } },
                           { "key" => "credit_card", "value" => { "stringValue" => "private-card" } } ]
    result = decode(span).spans.sole[:payload]
    expect(result["attributes"].first.dig("value", "stringValue")).to eq("[FILTERED]")
    expect(Base64.strict_decode64(result["attributes"].last.dig("value", "bytesValue"))).to eq("[FILTERED]")
    expect(decode(span.merge("name" => "invalid\u0000name")).rejected).to eq(1)
    span["attributes"] = [ { "key" => "binary", "value" => { "bytesValue" => Base64.strict_encode64("\xFF".b) } } ]
    expect(decode(span).rejected).to eq(1)
  end

  it "supports protobuf JSON nonfinite doubles and empty AnyValue defaults" do
    %w[NaN Infinity -Infinity].each do |number|
      attrs = [ { "key" => "number", "value" => { "doubleValue" => number } },
                { "key" => "future", "value" => { "futureField" => true } }, { "key" => "empty" } ]
      result = decode(span.merge("attributes" => attrs)).spans.sole[:payload]["attributes"]
      expect(result.last.dig("value", "doubleValue")).to eq(number)
      expect(result.first["value"]).to eq({})
    end
  end

  it "rejects attribute keys which collide after privacy scrubbing" do
    attrs = [ { "key" => "one@example.test", "value" => { "intValue" => "1" } },
              { "key" => "two@example.test", "value" => { "intValue" => "2" } } ]
    expect(decode(span.merge("attributes" => attrs)).rejected).to eq(1)
  end

  [ "arrayValue", "kvlistValue" ].each do |type|
    it "accepts eight #{type} levels and rejects nine, matching the receiver budget" do
      value = { "stringValue" => "leaf" }
      8.times do
        value = { type => { "values" => type == "arrayValue" ? [ value ] : [ { "key" => "child", "value" => value } ] } }
      end
      expect(decode(span.merge("attributes" => [ { "key" => "deep", "value" => value } ])).rejected).to eq(0)
      value = { type => { "values" => type == "arrayValue" ? [ value ] : [ { "key" => "child", "value" => value } ] } }
      expect(decode(span.merge("attributes" => [ { "key" => "deep", "value" => value } ])).rejected).to eq(1)
    end
  end
end
