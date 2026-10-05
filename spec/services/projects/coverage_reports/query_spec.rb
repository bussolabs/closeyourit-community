# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — l'estratto di copertura si rilegge dalle app e dalla riga di comando con la stessa
# domanda: per ramo, ordinato per nome del ramo.
RSpec.describe Projects::CoverageReports::Query do
  let(:project) { create(:project) }

  it "ordina per nome del ramo" do
    main = create(:coverage_report, project:, branch: "main")
    develop = create(:coverage_report, project:, branch: "develop")

    expect(described_class.call(project:).to_a).to eq([ develop, main ])
  end

  it "filtra per ramo, spazi in eccesso compresi" do
    main = create(:coverage_report, project:, branch: "main")
    create(:coverage_report, project:, branch: "develop")

    expect(described_class.call(project:, branch: " main ").to_a).to eq([ main ])
  end

  it "un ramo vuoto non filtra" do
    report = create(:coverage_report, project:, branch: "main")

    expect(described_class.call(project:, branch: "").to_a).to eq([ report ])
    expect(described_class.call(project:, branch: nil).to_a).to eq([ report ])
  end

  it "resta dentro il progetto chiesto" do
    mio = create(:coverage_report, project:)
    create(:coverage_report, project: create(:project, organization: project.organization))

    expect(described_class.call(project:).to_a).to eq([ mio ])
  end
end
