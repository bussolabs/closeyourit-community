# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::Monitoring::SymbolicationPresenter do
  it "keeps unavailable original frames separate from the failure reason" do
    event = Errors::Event.new(payload: {}, stacktrace: [])
    result = { "status" => "unresolved", "frames" => [ { "exception_index" => 5, "index" => 8, "status" => "missing_artifact" } ] }
    presenter = described_class.new(event: event, result: result)
    expect(presenter.rows.sole).to include(received: {}, exception: nil, status: "missing_artifact")
    expect(presenter.reason).to eq("missing_artifact")
  end

  it "shows a received Java line only when its original index exists" do
    event = Errors::Event.new(payload: { "platform" => "java", "exception" => { "values" => [ { "type" => "RuntimeException", "value" => "failure" } ] } })
    presenter = described_class.new(event: event, result: { "kind" => "proguard", "groups" => [ { "index" => 0, "kind" => "exception", "status" => "unmapped" } ] })
    expect(presenter.rows.sole[:received_line]).to include("RuntimeException")
  end
end
