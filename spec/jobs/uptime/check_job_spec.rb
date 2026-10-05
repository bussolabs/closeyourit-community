# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::CheckJob, type: :job do
  it "monitor attivo: pinga e registra un check" do
    monitor = create(:uptime_monitor, url: "https://up.test/health")
    allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
    stub_request(:get, "https://up.test/health").to_return(status: 200)
    expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
    expect(monitor.reload).to be_status_up
  end

  it "monitor inesistente → no-op" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end

  it "monitor in pausa → no-op (non attivo)" do
    monitor = create(:uptime_monitor, :paused)
    expect { described_class.perform_now(monitor.id) }.not_to change(Uptime::Check, :count)
  end
end
