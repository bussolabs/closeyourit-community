# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::ScanProjectJob do
  it "scansiona il progetto" do
    project = create(:project)
    allow(Vulnerabilities::ScanProject).to receive(:call).and_return(Result.ok(nil))

    described_class.perform_now(project.id)

    expect(Vulnerabilities::ScanProject).to have_received(:call).with(project: project)
  end

  it "un progetto cancellato fra il fan-out e l'esecuzione è un no-op" do
    allow(Vulnerabilities::ScanProject).to receive(:call)

    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    expect(Vulnerabilities::ScanProject).not_to have_received(:call)
  end

  it "serializza le scansioni dello stesso progetto, non quelle di progetti diversi" do
    # Solid Queue antepone il nome della classe alla chiave dichiarata.
    key = described_class.new("abc").concurrency_key

    expect(key).to end_with("vulnerabilities:scan:abc")
    expect(key).not_to eq(described_class.new("xyz").concurrency_key)
  end
end
