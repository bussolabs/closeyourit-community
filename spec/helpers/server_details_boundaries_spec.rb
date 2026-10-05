# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServerDetailsHelper, type: :helper do
  it "omits malformed samples and individual nonnumeric sensor readings" do
    sample = build(:server_sample, payload: { "temps" => { "valid" => 0, "invalid" => "high" }, "cores_usage" => [ 0, nil, "busy" ],
      "gpu" => { "0" => { "n" => "", "u" => "busy", "p" => nil }, "invalid" => [] },
      "per_nic" => { "invalid" => [], "missing" => nil }, "swap" => [], "disk_io_stats" => [ 0, 0, 0, 0, "slow" ] })
    expect(helper.server_temperature_sensors(sample)).to eq([ { name: "valid", value: 0.0 } ])
    expect(helper.server_core_usages(sample)).to eq([ { index: 0, pct: 0.0 } ])
    expect(helper.server_gpus(sample)).to eq([ { id: "0", name: "0", usage_pct: nil, watt: nil, memory_used_mb: nil, memory_total_mb: nil } ])
    expect(helper.server_network_interfaces(sample)).to eq([])
    expect(helper.server_swap(sample)).to be_nil
    expect(helper.server_disk_io(sample)).to be_nil
    expect(helper.server_gpus(nil)).to eq([])
    expect(helper.server_network_interfaces(nil)).to eq([])
    expect(helper.server_core_usages(nil)).to eq([])
  end
end
