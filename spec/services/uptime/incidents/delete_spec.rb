# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Incidents::Delete do
  before { allow(Uptime::Incidents::Broadcast).to receive(:incidents) }

  it "elimina l'incident e i suoi step, e fa broadcast della lista" do
    monitor = create(:uptime_monitor)
    incident = create(:uptime_incident, :narrated, monitor:)
    create(:uptime_incident_update, incident:, phase: :detected)

    result = nil
    expect { result = described_class.call(incident:) }
      .to change(Uptime::Incident, :count).by(-1)
      .and change(Uptime::IncidentUpdate, :count).by(-1)

    expect(result).to be_ok
    expect(Uptime::Incidents::Broadcast).to have_received(:incidents).with(monitor)
  end

  it "elimina a cascata anche le finestre unificate figlie" do
    monitor = create(:uptime_monitor)
    primary = create(:uptime_incident, :narrated, monitor:)
    create(:uptime_incident, monitor:, parent: primary)
    create(:uptime_incident, monitor:, parent: primary)

    expect { described_class.call(incident: primary) }
      .to change(Uptime::Incident, :count).by(-3)
  end

  it "incident singolo senza figli: Result.ok e record rimosso" do
    incident = create(:uptime_incident)

    expect(described_class.call(incident:)).to be_ok
    expect(Uptime::Incident.exists?(incident.id)).to be(false)
  end
end
