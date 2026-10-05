# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::Compare do
  def compare(operation, threshold, lower, upper, **bounds)
    described_class.call(config: { "comparison" => operation, "threshold" => threshold }, lower: BigDecimal(lower), upper: BigDecimal(upper), **bounds)
  end

  it "fires only when the entire uncertainty interval satisfies the threshold" do
    expect(compare("gt", "5", "0", "10")).to eq("unknown")
    expect(compare("gt", "0", "0", "10", lower_inclusive: false)).to eq("firing")
    expect(compare("gt", "0", "0", "10")).to eq("unknown")
    expect(compare("gte", "10", "0", "10", upper_inclusive: false)).to eq("safe")
    expect(compare("lt", "0", "-10", "0", upper_inclusive: false)).to eq("firing")
    expect(compare("lte", "-10", "-10", "0", lower_inclusive: false)).to eq("safe")
    expect(compare("gte", "0", "0", "0")).to eq("firing")
    expect(compare("lt", "0", "0", "0")).to eq("safe")
  end
end
