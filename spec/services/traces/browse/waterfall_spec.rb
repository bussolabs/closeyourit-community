# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Waterfall do
  def span(id, parent: nil, present: false, start: 1_780_000_000_000_000_001, finish: nil)
    Traces::Span.instantiate("span_id" => id, "parent_span_id" => parent, "observed_parent_present" => present,
      "start_time_unix_nano" => start, "end_time_unix_nano" => finish || start)
  end

  it "uses exact relative times before pixel quantization and preserves a known zero interval" do
    origin = 1_780_000_000_000_000_001
    record = span("a", start: origin + 1, finish: origin + 2)
    row = described_class.call(spans: [ record ], extent: [ origin, origin + 4 ]).sole
    expect(row).to include(duration_ns: 1, offset_ns: 1, left: "25.0", width: "25.0")
    row = described_class.call(spans: [ span("b") ], extent: [ origin, origin ]).sole
    expect(row).to include(duration_ns: 0, offset_ns: 0, left: "0", width: "0")
  end

  it "distinguishes received parents outside the page from missing parents and terminates cycles" do
    records = [ span("a", parent: "b", present: true), span("b", parent: "a", present: true),
      span("c", parent: "other", present: true), span("d", parent: "missing") ]
    rows = described_class.call(spans: records, extent: [ 1, 2 ])
    expect(rows.map { |row| row[:relation] }).to eq(%w[cycle cycle outside_page missing])
  end
end
