# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServerDetailsHelper, type: :helper do
  # Il payload vero di un DGX Spark, ridotto: è la forma che l'agent manda davvero.
  let(:payload) do
    {
      "temps" => { "GB10" => 45, "acpitz" => 49.8, "nvme_composite" => 38.85 },
      "cores_usage" => [ 1, 14, 50, 43 ],
      "cpu_breakdown" => [ 12.15, 2.33, 0.03, 0.0, 85.41 ],
      "gpu" => { "0" => { "n" => "GB10", "u" => 0, "p" => 11.2 } },
      "per_nic" => { "tailscale0" => [ 0, 0, 456_672, 2_122 ] },
      "swap" => { "used_gb" => 12.57, "total_gb" => 16 },
      "disk_io_stats" => [ 0, 1.71, 0.55, 0, 3.74, 1.71 ]
    }
  end
  let(:campione) { build(:server_sample, payload: payload) }

  describe "#server_temperature_sensors" do
    it "elenca i sensori dal più caldo" do
      expect(helper.server_temperature_sensors(campione).map { |s| s[:name] }).to eq(%w[acpitz GB10 nvme_composite])
    end

    it "senza campione non elenca niente" do
      expect(helper.server_temperature_sensors(nil)).to eq([])
    end
  end

  describe "#server_core_usages" do
    it "numera i processori a partire da zero" do
      expect(helper.server_core_usages(campione)).to eq([ { index: 0, pct: 1.0 }, { index: 1, pct: 14.0 },
                                                          { index: 2, pct: 50.0 }, { index: 3, pct: 43.0 } ])
    end
  end

  describe "#server_cpu_breakdown" do
    it "dà un nome a ciascuna delle cinque quote" do
      expect(helper.server_cpu_breakdown(campione)).to eq(user: 12.15, system: 2.33, iowait: 0.03,
                                                          steal: 0.0, idle: 85.41)
    end

    it "senza dettaglio non inventa niente" do
      expect(helper.server_cpu_breakdown(build(:server_sample, payload: {}))).to be_nil
    end
  end

  describe "#server_gpus" do
    it "legge nome, uso e watt di ogni scheda" do
      expect(helper.server_gpus(campione)).to eq([ { id: "0", name: "GB10", usage_pct: 0.0, watt: 11.2,
                                                     memory_used_mb: nil, memory_total_mb: nil } ])
    end
  end

  describe "#server_swap" do
    it "calcola quanto della memoria di scambio è occupato" do
      expect(helper.server_swap(campione)).to eq(used_gb: 12.57, total_gb: 16.0, pct: 78.56)
    end

    it "tace quando la macchina non ha memoria di scambio" do
      expect(helper.server_swap(build(:server_sample, payload: { "swap" => { "total_gb" => 0 } }))).to be_nil
    end
  end

  describe "#server_disk_io" do
    it "dà un nome alle sei misure del disco" do
      expect(helper.server_disk_io(campione)).to eq(read_pct: 0.0, write_pct: 1.71, util_pct: 0.55,
                                                    r_await_ms: 0.0, w_await_ms: 3.74)
    end
  end

  describe "#server_network_interfaces" do
    it "elenca il traffico di ogni interfaccia" do
      expect(helper.server_network_interfaces(campione)).to eq([ { name: "tailscale0", sent_bytes: 456_672,
                                                                  recv_bytes: 2_122 } ])
    end
  end

  describe "#server_meter_color" do
    it "dà un simbolo che il componente barra sa usare, non una classe CSS" do
      expect(Ui::MeterComponent::COLORS).to have_key(helper.server_meter_color(10))
    end

    it "usa le stesse soglie del resto della pagina" do
      expect(helper.server_meter_color(10)).to eq(:emerald)
      expect(helper.server_meter_color(60)).to eq(:amber)
      expect(helper.server_meter_color(90)).to eq(:red)
      expect(helper.server_meter_color(nil)).to eq(:neutral)
    end
  end
end
