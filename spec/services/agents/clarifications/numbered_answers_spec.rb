# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Clarifications::NumberedAnswers do
  it "splits the parts by number and keeps the gaps" do
    expect(described_class.call(body: "\n3. Third\n\n1. First", count: 3)).to eq([ "First", nil, "Third" ])
  end

  it "returns nil without any number" do
    expect(described_class.call(body: "Just a comment", count: 2)).to be_nil
  end

  it "returns nil when a number repeats" do
    expect(described_class.call(body: "1. Yes\n1. No", count: 2)).to be_nil
  end

  it "returns nil for a number outside the round" do
    expect(described_class.call(body: "0. Zero", count: 2)).to be_nil
  end
end
