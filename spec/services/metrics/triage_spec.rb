# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Triage, type: :service do
  let(:group) { create(:metric_group, status: :unresolved) }

  it "resolve → resolved" do
    expect(described_class.call(group:, action: "resolve")).to be_ok
    expect(group.reload).to be_status_resolved
  end

  it "ignore → ignored" do
    described_class.call(group:, action: "ignore")
    expect(group.reload).to be_status_ignored
  end

  it "reopen → unresolved (da resolved o ignored)" do
    group.status_resolved!
    described_class.call(group:, action: "reopen")
    expect(group.reload).to be_status_unresolved
  end

  it "azione sconosciuta → err R422-METRIC-005, stato invariato" do
    result = described_class.call(group:, action: "bogus")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-METRIC-005")
    expect(group.reload).to be_status_unresolved
  end
end
