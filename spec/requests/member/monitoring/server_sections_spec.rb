# frozen_string_literal: true

require "rails_helper"

# CYRA-703 — la scheda di una macchina mostrava quattro numeri su dieci. Qui si presidia che ogni
# dato che l'agent manda abbia un posto in pagina, e che una sezione compaia SOLO se quella
# macchina quel dato lo manda davvero.
RSpec.describe "Member::Monitoring::Servers — le sezioni della scheda (CYRA-703)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:server_host, :up, organization: org, name: "spark") }

  # Il payload vero di un DGX Spark, ridotto alle chiavi che contano.
  let(:payload_completo) do
    {
      "temps" => { "GB10" => 45, "acpitz" => 49.8, "nvme_composite" => 38.85 },
      "cores_usage" => [ 1, 14, 50, 43 ],
      "cpu_breakdown" => [ 12.15, 2.33, 0.03, 0.0, 85.41 ],
      "gpu" => { "0" => { "n" => "GB10", "u" => 0, "p" => 11.2 } },
      "per_nic" => { "tailscale0" => [ 0, 0, 456_672, 2_122 ] },
      "swap" => { "used_gb" => 12.57, "total_gb" => 16 },
      "mem" => { "used_gb" => 100.19, "total_gb" => 121.63 },
      "disk_io_stats" => [ 0, 1.71, 0.55, 0, 3.74, 1.71 ]
    }
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "Scenario 1: la scheda grafica ha la sua sezione" do
    before do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             gpu_pct: 0.0, gpu_watt: 11.2, temp_max: 49.8, payload: payload_completo)
    end

    it "mostra la sezione con nome, uso e watt della scheda" do
      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-section-gpu"')
      expect(response.body).to include("GB10")
      expect(response.body).to include("11.2")
    end

    it "dichiara che la memoria della scheda non è disponibile invece di mostrare zero" do
      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-gpu-memory-unavailable"')
    end
  end

  describe "Scenario 2: tutti i sensori di temperatura, con il loro nome" do
    before do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             temp_max: 49.8, payload: payload_completo)
    end

    it "elenca ogni sensore col suo nome accanto al grafico del più caldo" do
      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-section-temperature"')
      expect(response.body.scan('data-test="server-sensor"').size).to eq(3)
      expect(response.body).to include("nvme_composite")
    end

    it "su una macchina senza sensori la sezione non c'è" do
      host.samples.delete_all
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             temp_max: nil, payload: {})

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).not_to include('data-test="server-section-temperature"')
    end
  end

  describe "Scenario 3: una sezione compare solo se il dato arriva" do
    it "su una macchina senza scheda grafica la sezione non c'è" do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago, payload: {})

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).not_to include('data-test="server-section-gpu"')
    end
  end

  describe "Scenario 4: la CPU si legge per quote e per singolo processore" do
    before do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             cpu_pct: 14.5, payload: payload_completo)
    end

    it "mostra la ripartizione fra utente, sistema, attesa disco e tempo rubato" do
      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-cpu-breakdown"')
    end

    it "mostra una barra per ogni processore" do
      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body.scan('data-test="server-core"').size).to eq(4)
    end

    it "su un agent che non manda il dettaglio mostra comunque il grafico principale" do
      host.samples.delete_all
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             cpu_pct: 14.5, payload: {})

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-section-cpu"')
      expect(response.body).not_to include('data-test="server-cpu-breakdown"')
    end
  end

  describe "Scenario 5: la memoria di scambio diventa visibile" do
    it "mostra quanta memoria di scambio è occupata" do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             mem_pct: 82.4, payload: payload_completo)

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-swap"')
      expect(response.body).to include("12.57")
    end

    it "su una macchina senza memoria di scambio non mostra il blocco" do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             mem_pct: 40.0, payload: { "swap" => { "total_gb" => 0, "used_gb" => 0 } })

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-section-memory"')
      expect(response.body).not_to include('data-test="server-swap"')
    end
  end

  describe "Scenario 6: il disco dice anche quanto è lento" do
    it "mostra saturazione e attese di lettura e scrittura" do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             disk_pct: 17.3, payload: payload_completo)

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-disk-io"')
      expect(response.body).to include("3.74")
    end

    it "tiene i filesystem nella sezione del disco" do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             disk_pct: 17.3, payload: payload_completo.merge(
               "extra_fs" => { "nvme0n1p1" => { "d" => 0.5, "du" => 0.01 } }))

      get member_monitoring_server_path(host, tab: "metrics")

      sezione = response.body.index('data-test="server-section-disk"')
      dischi = response.body.index('data-test="server-disks"')
      expect(dischi).to be > sezione
    end
  end

  describe "Scenario 7: il traffico di rete" do
    it "mostra il grafico del traffico e le singole interfacce" do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             net_sent_bytes: 5_000, net_recv_bytes: 9_000, payload: payload_completo)

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include('data-test="server-section-network"')
      expect(response.body).to include('data-test="server-nic"')
      expect(response.body).to include("tailscale0")
    end
  end
end
