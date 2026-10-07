# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coworkers::Worker, "usage events" do
  let(:run) { Coworkers::Run.new(kind: "chat", status: "running", output: "", runtime_state: {}, tools: [], tokens_used: 10, tokens_reserved: 100) }

  it "keeps the highest token count, capped at twice the reservation" do
    described_class.apply(run, { "type" => "usage", "tokens" => 5 })
    expect(run.tokens_used).to eq(10)
    described_class.apply(run, { "type" => "usage", "tokens" => 150 })
    expect(run.tokens_used).to eq(150)
    described_class.apply(run, { "type" => "usage", "tokens" => 999 })
    expect(run.tokens_used).to eq(200)
  end

  it "rejects a token count that is not a non-negative integer" do
    [ -1, "50", nil ].each do |tokens|
      expect { described_class.apply(run, { "type" => "usage", "tokens" => tokens }) }.to raise_error(described_class::InvalidEvent)
    end
    expect(run.tokens_used).to eq(10)
  end
end
