# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::EnsurePartitionsJob, type: :job do
  it "gira sulla corsia dei controlli: dura secondi e non deve mettersi in coda dietro le potature" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end

  it "chiede le fette mancanti" do
    allow(Ops::Partitions::Ensure).to receive(:call).and_return([])

    described_class.perform_now

    expect(Ops::Partitions::Ensure).to have_received(:call)
  end

  it "scrive nei log solo quando ha creato qualcosa" do
    allow(Ops::Partitions::Ensure).to receive(:call).and_return([ "logs_entries_p2027_01" ])
    allow(Rails.logger).to receive(:info)

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(/logs_entries_p2027_01/)
  end
end
