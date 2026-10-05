# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Incidents::AddUpdate do
  before { allow(Uptime::Incidents::Broadcast).to receive(:incidents) }

  let(:incident) { create(:uptime_incident, :narrated) }
  let(:actor)    { create(:account) }

  it "appende uno step e denormalizza la phase corrente" do
    result = described_class.call(incident:, phase: "resolved", body: "Rientrato: era il DNS.", actor:)

    expect(result).to be_ok
    expect(result.value).to have_attributes(phase: "resolved", body: "Rientrato: era il DNS.", created_by_id: actor.id)
    expect(incident.reload.phase).to eq("resolved")
    expect(Uptime::Incidents::Broadcast).to have_received(:incidents).with(incident.monitor)
  end

  it "phase non valida → R422-UPTIME-002" do
    result = described_class.call(incident:, phase: "nope")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-UPTIME-002")
    expect(incident.reload.updates).to be_empty
  end
end
