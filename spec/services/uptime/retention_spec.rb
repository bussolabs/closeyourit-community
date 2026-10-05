# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Retention do
  let(:project) { create(:project) }
  let(:organization) { project.organization }

  before { Settings::Global.instance.update!(uptime_retention_days: 730) }

  it "usa l'override del progetto quando presente (nearest-wins, non cap)" do
    organization.update!(uptime_retention_days: 400)
    project.update!(uptime_retention_days: 365)
    expect(described_class.for(project)).to eq(365)
  end

  it "eredita dall'org se il progetto non ha override" do
    organization.update!(uptime_retention_days: 400)
    expect(described_class.for(project)).to eq(400)
  end

  it "eredita dal god globale se né progetto né org" do
    expect(described_class.for(project)).to eq(730)
  end

  it "ripiega sul default di sistema se anche il global pre-risolto è nil" do
    expect(described_class.for(project, global_days: nil)).to eq(Uptime::Constants::RETENTION_DEFAULT_DAYS)
  end

  it "usa il global pre-risolto passato dal chiamante (no rilettura di Settings::Global)" do
    expect(described_class.for(project, global_days: 100)).to eq(100)
  end

  it "un valore blank a un livello eredita dal superiore" do
    organization.update!(uptime_retention_days: 400)
    project.update!(uptime_retention_days: "")
    expect(described_class.for(project)).to eq(400)
  end
end
