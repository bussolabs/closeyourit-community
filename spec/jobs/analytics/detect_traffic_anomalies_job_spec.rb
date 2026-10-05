# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::DetectTrafficAnomaliesJob, type: :job do
  it "delega al detector e ritorna il numero di anomalie segnalate" do
    allow(Analytics::DetectTrafficAnomalies).to receive(:call).and_return(Result.ok(3))
    expect(described_class.new.perform).to eq(3)
  end

  it "gira sulla coda :maintenance" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
