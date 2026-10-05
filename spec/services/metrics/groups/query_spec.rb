# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — stessa lista per i due canali a token: una domanda sola.
RSpec.describe Metrics::Groups::Query do
  let(:project) { create(:project) }

  it "ordina dal visto più di recente" do
    vecchio = create(:metric_group, project:, last_seen_at: 2.hours.ago)
    nuovo   = create(:metric_group, project:, last_seen_at: 1.minute.ago)

    expect(described_class.call(project:).to_a).to eq([ nuovo, vecchio ])
  end

  it "resta dentro il progetto chiesto" do
    mio = create(:metric_group, project:)
    create(:metric_group, project: create(:project, organization: project.organization))

    expect(described_class.call(project:).to_a).to eq([ mio ])
  end

  it "filtra per tipo quando il tipo esiste" do
    create(:metric_group, project:, kind: :slow_query)
    metodo = create(:metric_group, project:, kind: :slow_method)

    expect(described_class.call(project:, kind: "slow_method").to_a).to eq([ metodo ])
  end

  it "ignora un tipo che non esiste invece di svuotare la lista" do
    gruppo = create(:metric_group, project:)

    expect(described_class.call(project:, kind: "inventato").to_a).to eq([ gruppo ])
    expect(described_class.call(project:, kind: nil).to_a).to eq([ gruppo ])
  end
end
