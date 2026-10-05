# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::BulkTriage, type: :service do
  let(:project) { create(:project) }
  let(:scope) { Errors::Group.where(project:) }

  it "resolve → tutti i gruppi selezionati diventano resolved" do
    a = create(:error_group, project:, status: :unresolved)
    b = create(:error_group, project:, status: :unresolved)
    result = described_class.call(scope:, ids: [ a.id, b.id ], action: "resolve")

    expect(result).to be_ok
    expect(result.value.map(&:id)).to contain_exactly(a.id, b.id)
    expect(a.reload).to be_status_resolved
    expect(b.reload).to be_status_resolved
  end

  it "ignore → tutti i gruppi selezionati diventano ignored" do
    a = create(:error_group, project:, status: :unresolved)
    described_class.call(scope:, ids: [ a.id ], action: "ignore")
    expect(a.reload).to be_status_ignored
  end

  it "reopen → i gruppi risolti/ignorati tornano unresolved" do
    a = create(:error_group, project:, status: :resolved)
    b = create(:error_group, project:, status: :ignored)
    described_class.call(scope:, ids: [ a.id, b.id ], action: "reopen")
    expect(a.reload).to be_status_unresolved
    expect(b.reload).to be_status_unresolved
  end

  it "anti-BOLA: un id fuori scope viene scartato, non tocca gli altri" do
    inside = create(:error_group, project:, status: :unresolved)
    outside = create(:error_group, status: :unresolved) # altro progetto → fuori dallo scope

    result = described_class.call(scope:, ids: [ inside.id, outside.id ], action: "resolve")

    expect(result.value.map(&:id)).to contain_exactly(inside.id)
    expect(inside.reload).to be_status_resolved
    expect(outside.reload).to be_status_unresolved
  end

  it "ids vuoto → ok, nessun gruppo toccato" do
    a = create(:error_group, project:, status: :unresolved)
    result = described_class.call(scope:, ids: [], action: "resolve")
    expect(result.value).to be_empty
    expect(a.reload).to be_status_unresolved
  end

  it "azione non valida → err R422-ERROR-002, nulla cambia" do
    a = create(:error_group, project:, status: :unresolved)
    result = described_class.call(scope:, ids: [ a.id ], action: "bogus")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-ERROR-002")
    expect(a.reload).to be_status_unresolved
  end

  it "scarta gli id blank in ingresso (checkbox spurie)" do
    a = create(:error_group, project:, status: :unresolved)
    result = described_class.call(scope:, ids: [ "", a.id, nil ], action: "resolve")
    expect(result.value.map(&:id)).to contain_exactly(a.id)
  end
end
