# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Incidents::GroupAndUpdate do
  # La lista incident viene ribroadcastata via Turbo (rende un partial) — fuori dal perimetro del service.
  before { allow(Uptime::Incidents::Broadcast).to receive(:incidents) }

  let(:monitor) { create(:uptime_monitor) }
  let(:actor)   { create(:account) }

  it "unifica ≥2 incident sotto il più vecchio e posta il primo step" do
    old = create(:uptime_incident, monitor:, started_at: 2.hours.ago)
    newer = create(:uptime_incident, monitor:, started_at: 10.minutes.ago)

    result = described_class.call(monitor:, incident_ids: [ old.id, newer.id ],
                                  phase: "investigating", body: "Indaghiamo", actor:)

    expect(result).to be_ok
    primary = result.value
    expect(primary).to eq(old) # il più vecchio
    expect(newer.reload.parent_id).to eq(old.id)
    expect(primary.reload.phase).to eq("investigating")
    expect(primary.updates.count).to eq(1)
    expect(primary.updates.first).to have_attributes(phase: "investigating", body: "Indaghiamo", created_by_id: actor.id)
    expect(Uptime::Incidents::Broadcast).to have_received(:incidents).with(monitor)
  end

  it "con un solo incident non raggruppa, posta solo lo step" do
    inc = create(:uptime_incident, monitor:)
    result = described_class.call(monitor:, incident_ids: [ inc.id ], phase: "detected", actor:)

    expect(result).to be_ok
    expect(inc.reload.parent_id).to be_nil
    expect(inc.phase).to eq("detected")
    expect(inc.updates.count).to eq(1)
  end

  it "appiattisce i figli già esistenti degli altri selezionati (un solo livello)" do
    primary = create(:uptime_incident, monitor:, started_at: 3.hours.ago)
    other = create(:uptime_incident, monitor:, started_at: 1.hour.ago)
    grandchild = create(:uptime_incident, monitor:, parent: other, started_at: 90.minutes.ago)

    described_class.call(monitor:, incident_ids: [ primary.id, other.id ], phase: "monitoring")

    expect(other.reload.parent_id).to eq(primary.id)
    expect(grandchild.reload.parent_id).to eq(primary.id) # riparentato sotto il primary, non annidato
  end

  it "anti-BOLA: incident di un altro monitor → R422-UPTIME-001" do
    mine = create(:uptime_incident, monitor:)
    foreign = create(:uptime_incident) # altro monitor

    result = described_class.call(monitor:, incident_ids: [ mine.id, foreign.id ], phase: "investigating")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-UPTIME-001")
    expect(foreign.reload.parent_id).to be_nil
  end

  it "id di un figlio (non top-level) → R422-UPTIME-001" do
    primary = create(:uptime_incident, monitor:)
    child = create(:uptime_incident, monitor:, parent: primary)

    result = described_class.call(monitor:, incident_ids: [ child.id ], phase: "investigating")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-UPTIME-001")
  end

  it "phase non valida → R422-UPTIME-002, nessuna scrittura" do
    inc = create(:uptime_incident, monitor:)
    result = described_class.call(monitor:, incident_ids: [ inc.id ], phase: "bogus")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-UPTIME-002")
    expect(inc.reload.updates).to be_empty
  end
end
