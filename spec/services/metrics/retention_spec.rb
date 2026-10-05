# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Retention do
  let(:project) { create(:project) }
  let(:organization) { project.organization }

  before { Settings::Global.instance.update!(performance_retention_days: 30) }

  it "usa l'override del progetto quando presente (nearest-wins, non cap)" do
    organization.update!(performance_retention_days: 90)
    project.update!(performance_retention_days: 7)
    expect(described_class.for(project)).to eq(7)
  end

  it "eredita dall'org se il progetto non ha override" do
    organization.update!(performance_retention_days: 60)
    expect(described_class.for(project)).to eq(60)
  end

  it "eredita dal god globale se né progetto né org" do
    expect(described_class.for(project)).to eq(30)
  end

  it "ripiega sul default di sistema se anche il global pre-risolto è nil" do
    expect(described_class.for(project, global_days: nil)).to eq(Metrics::Constants::RETENTION_DEFAULT_DAYS)
  end

  it "usa il global pre-risolto passato dal chiamante (no rilettura di Settings::Global)" do
    expect(described_class.for(project, global_days: 21)).to eq(21)
  end

  it "un valore blank a un livello eredita dal superiore" do
    organization.update!(performance_retention_days: 60)
    project.update!(performance_retention_days: "")
    expect(described_class.for(project)).to eq(60)
  end
end
