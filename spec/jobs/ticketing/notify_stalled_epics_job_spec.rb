# frozen_string_literal: true

require "rails_helper"

# CYRA-1155 — the hourly round that finds stalled epics and notifies them.
RSpec.describe Ticketing::NotifyStalledEpicsJob do
  it "notifies every stalled epic and returns how many notices went out" do
    stalls = [ instance_double(Ticketing::StalledEpics::Detect::Stall), instance_double(Ticketing::StalledEpics::Detect::Stall) ]
    allow(Ticketing::StalledEpics::Detect).to receive(:call).and_return(Result.ok(stalls))
    allow(Ticketing::StalledEpics::Notify).to receive(:call).and_return(Result.ok(2))

    expect(described_class.perform_now).to eq(4)
    expect(Ticketing::StalledEpics::Notify).to have_received(:call).twice
  end

  it "runs every hour on the short-checks lane" do
    recurring = YAML.load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
    task = recurring.fetch("production").values.find { |entry| entry["class"] == described_class.name }

    expect(task).to include("queue" => "maintenance")
    expect(task["schedule"]).to start_with("every hour")
  end
end
