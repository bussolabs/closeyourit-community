# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::BulkTriage, type: :service do
  let(:project) { create(:project) }
  let(:scope) { Metrics::Group.where(project:) }

  it "resolve → tutti i gruppi selezionati diventano resolved" do
    a = create(:metric_group, project:, status: :unresolved)
    b = create(:metric_group, project:, status: :unresolved)
    result = described_class.call(scope:, ids: [ a.id, b.id ], action: "resolve")

    expect(result).to be_ok
    expect(result.value.map(&:id)).to contain_exactly(a.id, b.id)
    expect(a.reload).to be_status_resolved
    expect(b.reload).to be_status_resolved
  end

  it "ignore → tutti i gruppi selezionati diventano ignored" do
    a = create(:metric_group, project:, status: :unresolved)
    described_class.call(scope:, ids: [ a.id ], action: "ignore")
    expect(a.reload).to be_status_ignored
  end

  it "reopen → i gruppi risolti/ignorati tornano unresolved" do
    a = create(:metric_group, project:, status: :ignored)
    described_class.call(scope:, ids: [ a.id ], action: "reopen")
    expect(a.reload).to be_status_unresolved
  end

  it "anti-BOLA: un id fuori scope viene scartato, non tocca gli altri" do
    inside = create(:metric_group, project:, status: :unresolved)
    outside = create(:metric_group, status: :unresolved)

    result = described_class.call(scope:, ids: [ inside.id, outside.id ], action: "resolve")

    expect(result.value.map(&:id)).to contain_exactly(inside.id)
    expect(inside.reload).to be_status_resolved
    expect(outside.reload).to be_status_unresolved
  end

  it "azione non valida → err R422-METRIC-005, nulla cambia" do
    a = create(:metric_group, project:, status: :unresolved)
    result = described_class.call(scope:, ids: [ a.id ], action: "bogus")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-METRIC-005")
    expect(a.reload).to be_status_unresolved
  end
end
