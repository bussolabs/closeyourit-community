# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Retention do
  let(:organization) { create(:organization) }

  before { Settings::Global.instance.update!(servers_retention_days: 30) }

  it "usa l'override dell'org quando presente (nearest-wins, non cap)" do
    organization.update!(servers_retention_days: 15)
    expect(described_class.for(organization)).to eq(15)
  end

  it "eredita dal god globale se l'org non ha override" do
    expect(described_class.for(organization)).to eq(30)
  end

  it "ripiega sul default di sistema se anche il global pre-risolto è nil" do
    expect(described_class.for(organization, global_days: nil)).to eq(Servers::Constants::RETENTION_DEFAULT_DAYS)
  end

  it "usa il global pre-risolto passato dal chiamante (no rilettura di Settings::Global)" do
    expect(described_class.for(organization, global_days: 21)).to eq(21)
  end

  it "un valore blank a livello org eredita dal god" do
    organization.update!(servers_retention_days: "")
    expect(described_class.for(organization)).to eq(30)
  end
end
