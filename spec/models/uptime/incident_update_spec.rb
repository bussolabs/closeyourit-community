# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::IncidentUpdate, type: :model do
  it "factory valida" do
    expect(build(:uptime_incident_update)).to be_valid
  end

  it "richiede una phase" do
    expect(build(:uptime_incident_update, phase: nil)).not_to be_valid
  end

  it "normalizza body vuoto a nil (body opzionale)" do
    u = create(:uptime_incident_update, body: "   ")
    expect(u.body).to be_nil
  end

  it "espone le phase a step" do
    expect(described_class.phases.keys).to eq(%w[detected investigating fixing monitoring resolved])
  end

  describe ".chronological" do
    it "ordina per created_at poi id (deterministico a parità di istante)" do
      inc = create(:uptime_incident)
      a = create(:uptime_incident_update, incident: inc, phase: :detected)
      b = create(:uptime_incident_update, incident: inc, phase: :resolved)
      expect(described_class.chronological.to_a).to eq([ a, b ])
    end
  end

  it "created_by opzionale (sopravvive alla cancellazione account → nullify)" do
    expect(build(:uptime_incident_update, created_by: nil)).to be_valid
  end
end
