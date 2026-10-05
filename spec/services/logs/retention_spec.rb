# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Retention do
  let(:project) { create(:project) }
  let(:organization) { project.organization }

  before { Settings::Global.instance.update!(logs_retention_days: 14) }

  it "usa l'override del progetto quando presente (nearest-wins, non cap)" do
    organization.update!(logs_retention_days: 30)
    project.update!(logs_retention_days: 7)
    expect(described_class.for(project)).to eq(7)
  end

  it "eredita dall'org se il progetto non ha override" do
    organization.update!(logs_retention_days: 30)
    expect(described_class.for(project)).to eq(30)
  end

  it "eredita dal god globale se né progetto né org" do
    expect(described_class.for(project)).to eq(14)
  end

  it "ripiega sul default di sistema se anche il global pre-risolto è nil" do
    # Il god è obbligatorio (Settings::Global presence); il fallback finale resta come doppia rete
    # quando il chiamante (es. il job) passa esplicitamente un global già risolto a nil.
    expect(described_class.for(project, global_days: nil)).to eq(Logs::Constants::RETENTION_DEFAULT_DAYS)
  end

  it "usa il global pre-risolto passato dal chiamante (no rilettura di Settings::Global)" do
    expect(described_class.for(project, global_days: 21)).to eq(21)
  end

  it "un valore blank a un livello eredita dal superiore" do
    organization.update!(logs_retention_days: 30)
    project.update!(logs_retention_days: "")
    expect(described_class.for(project)).to eq(30)
  end
end
