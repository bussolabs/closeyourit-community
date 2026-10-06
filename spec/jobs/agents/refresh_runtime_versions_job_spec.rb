# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::RefreshRuntimeVersionsJob do
  it "refreshes the latest releases of the programs the machines report" do
    allow(Agents::RuntimeVersions).to receive(:refresh!)

    described_class.perform_now

    expect(Agents::RuntimeVersions).to have_received(:refresh!)
  end
end
