# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::ReconcileAlertsJob, type: :job do
  it "gira sulla corsia dei controlli periodici" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end

  it "delega il recupero al service e ne restituisce il conto" do
    allow(Uptime::ReconcileAlerts).to receive(:call).and_return(Result.ok(3))

    expect(described_class.perform_now).to eq(3)
  end

  # Un avviso recuperato vuol dire che la consegna normale non ha funzionato: deve leggersi nei log,
  # non restare un fatto muto.
  it "scrive nei log quando ha recuperato qualcosa" do
    allow(Uptime::ReconcileAlerts).to receive(:call).and_return(Result.ok(2))
    expect(Rails.logger).to receive(:warn).with(/2/)

    described_class.perform_now
  end

  it "tace quando non c'è niente da recuperare" do
    allow(Uptime::ReconcileAlerts).to receive(:call).and_return(Result.ok(0))
    expect(Rails.logger).not_to receive(:warn)

    described_class.perform_now
  end
end
