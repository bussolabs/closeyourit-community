# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Incidents::Ungroup do
  before { allow(Uptime::Incidents::Broadcast).to receive(:incidents) }

  it "stacca tutti i figli; la narrazione resta sul primary" do
    monitor = create(:uptime_monitor)
    primary = create(:uptime_incident, :narrated, monitor:)
    child_a = create(:uptime_incident, monitor:, parent: primary)
    child_b = create(:uptime_incident, monitor:, parent: primary)

    result = described_class.call(incident: primary)

    expect(result).to be_ok
    expect(child_a.reload.parent_id).to be_nil
    expect(child_b.reload.parent_id).to be_nil
    expect(primary.reload.phase).to eq("investigating")
    expect(Uptime::Incidents::Broadcast).to have_received(:incidents).with(monitor)
  end

  it "idempotente senza figli (no-op)" do
    inc = create(:uptime_incident)
    expect(described_class.call(incident: inc)).to be_ok
  end

  it "keep_incident_id di un figlio → sposta phase + timeline su quel figlio, il primary resta nudo" do
    monitor = create(:uptime_monitor)
    primary = create(:uptime_incident, :narrated, monitor:)
    create(:uptime_incident_update, incident: primary, phase: :investigating)
    create(:uptime_incident_update, incident: primary, phase: :resolved)
    keeper = create(:uptime_incident, monitor:, parent: primary)
    other = create(:uptime_incident, monitor:, parent: primary)

    result = described_class.call(incident: primary, keep_incident_id: keeper.id)

    expect(result).to be_ok
    expect(keeper.reload.parent_id).to be_nil
    expect(keeper.phase).to eq("investigating")
    expect(keeper.updates.count).to eq(2)
    expect(primary.reload.phase).to be_nil
    expect(primary.updates.count).to eq(0)
    expect(other.reload.parent_id).to be_nil
  end

  it "keep_incident_id estraneo (non figlio) → fail-safe: narrazione resta sul primary" do
    monitor = create(:uptime_monitor)
    primary = create(:uptime_incident, :narrated, monitor:)
    child = create(:uptime_incident, monitor:, parent: primary)
    foreign = create(:uptime_incident, monitor:) # top-level, non figlio

    result = described_class.call(incident: primary, keep_incident_id: foreign.id)

    expect(result).to be_ok
    expect(primary.reload.phase).to eq("investigating")
    expect(child.reload.parent_id).to be_nil
    expect(foreign.reload.phase).to be_nil
  end

  it "splitta e resta ok anche se il broadcast fallisce (update_all committato → niente 500)" do
    allow(Uptime::Incidents::Broadcast).to receive(:incidents).and_call_original
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to).and_raise(StandardError, "cable down")
    monitor = create(:uptime_monitor)
    primary = create(:uptime_incident, :narrated, monitor:)
    child = create(:uptime_incident, monitor:, parent: primary)

    result = described_class.call(incident: primary)

    expect(result).to be_ok
    expect(child.reload.parent_id).to be_nil
  end
end
