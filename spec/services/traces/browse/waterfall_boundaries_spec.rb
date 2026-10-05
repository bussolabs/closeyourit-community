# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Waterfall do
  it "keeps absent extents unknown while preserving ancestry and exact duration" do
    root = Traces::Span.instantiate("span_id" => "a", "parent_span_id" => nil, "start_time_unix_nano" => 10, "end_time_unix_nano" => 20)
    child = Traces::Span.instantiate("span_id" => "b", "parent_span_id" => "a", "start_time_unix_nano" => 12, "end_time_unix_nano" => 15)
    rows = described_class.call(spans: [ root, child ], extent: [ nil, nil ])
    expect(rows.first).to include(depth: 0, relation: "root", offset_ns: nil, left: "0", width: "0")
    expect(rows.last).to include(depth: 1, relation: "child", duration_ns: 3, offset_ns: nil)
    partial = described_class.call(spans: [ root ], extent: [ 10, nil ]).sole
    expect(partial).to include(offset_ns: 0, left: "0", width: "0")
  end
end
