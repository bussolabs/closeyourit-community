# frozen_string_literal: true

require "rails_helper"

# CYRA-564 — la scheda di una macchina metteva in fondo proprio ciò per cui la si apre: dischi,
# ambienti collegati, prossimi passi e azioni operative arrivavano DOPO il registro degli errori di
# sistema, che su una macchina di build occupava da solo quasi due terzi della pagina. Qui si presidia
# l'ordine dei riquadri (chi decide sta in alto) e il fatto che i blocchi lunghi scorrono dentro il
# proprio riquadro, così l'altezza della pagina non dipende più da quante righe ha il registro oggi.
RSpec.describe "Member::Monitoring::Servers — la scheda mette in alto ciò che serve (CYRA-564)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) do
    create(:server_host, organization: org, name: "ci-runner-1", status: :up, last_seen_at: Time.current,
           services_total: 40, services_failed: 1,
           systemd_services: [ { "name" => "backup.service", "state" => "failed", "sub" => "failed" },
                               { "name" => "ssh.service", "state" => "active", "sub" => "running" } ])
  end

  # Posizione del riquadro nel documento: l'ordine di lettura è esattamente l'oggetto del ticket.
  def posizione(test_id)
    response.body.index(%(data-test="#{test_id}"))
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # Scenarios 1 and 2 (what decides above the logs) are now answered by the tabs: the overview opens
  # on what needs doing, and the logs live in their own tabs (server_tabs_spec).

  describe "Definition of Done: i registri lunghi non allungano la pagina" do
    def riquadro(selettore)
      Nokogiri::HTML(response.body).at_css(selettore)
    end

    it "on its own tab the system log grows with the page instead of scrolling in a short box" do
      allow_n_plus_one do
        create_list(:server_journal_entry, 3, host: host, organization: org, occurred_at: 5.minutes.ago)
      end

      get member_monitoring_server_path(host, tab: "log")

      classi = riquadro("[data-test='server-journal-list']")["class"]
      expect(classi).not_to match(/max-h-/)
    end

    it "l'elenco completo dei servizi scorre dentro il proprio riquadro" do
      get member_monitoring_server_path(host, tab: "workloads")

      classi = riquadro("[data-test='server-systemd-full-list']")["class"]
      expect(classi).to include("overflow-y-auto")
      expect(classi).to match(/max-h-/)
    end

    it "la tabella dei container scorre dentro il proprio riquadro" do
      create(:server_container_sample, host: host, name: "web", recorded_at: 1.minute.ago)

      get member_monitoring_server_path(host, tab: "workloads")

      classi = riquadro("[data-test='server-containers-table']")["class"]
      expect(classi).to match(/overflow-(y-)?auto/)
      expect(classi).to match(/max-h-/)
    end

    it "la tabella dei container tiene l'intestazione in vista mentre si scorre" do
      create(:server_container_sample, host: host, name: "web", recorded_at: 1.minute.ago)

      get member_monitoring_server_path(host, tab: "workloads")

      expect(riquadro("[data-test='server-containers-table'] thead")["class"]).to include("sticky")
    end

    it "le righe di journal catturate per una unit in errore restano dentro un'altezza fissa" do
      host.update!(journal_snapshots: { "backup.service" => { "captured_at" => Time.current.iso8601,
                                                              "lines" => [ "systemd[1]: backup.service entered failed state" ] } })

      get member_monitoring_server_path(host, tab: "workloads")

      classi = riquadro("[data-test='server-systemd-snapshot'] pre")["class"]
      expect(classi).to match(/max-h-/)
      expect(classi).to include("overflow-auto")
    end
  end

  describe "Scenario 3: le sezioni tematiche in ordine di lettura (CYRA-703)" do
    before do
      create(:server_sample, host: host, organization: org, recorded_at: 1.minute.ago,
             cpu_pct: 14.5, mem_pct: 82.4, disk_pct: 17.3, temp_max: 49.8,
             gpu_pct: 0.0, gpu_watt: 11.2,
             payload: { "temps" => { "GB10" => 45 }, "cores_usage" => [ 1, 14 ],
                        "cpu_breakdown" => [ 12.15, 2.33, 0.03, 0.0, 85.41 ],
                        "gpu" => { "0" => { "n" => "GB10", "u" => 0, "p" => 11.2 } },
                        "per_nic" => { "eth0" => [ 0, 0, 100, 200 ] },
                        "swap" => { "used_gb" => 12.57, "total_gb" => 16 },
                        "disk_io_stats" => [ 0, 1.71, 0.55, 0, 3.74, 1.71 ] })
    end

    it "tiene l'ordine processore, memoria, disco, rete, scheda grafica, temperature" do
      get member_monitoring_server_path(host, tab: "metrics")

      ordine = %w[server-section-cpu server-section-memory server-section-disk
                  server-section-network server-section-gpu server-section-temperature]
      posizioni = ordine.map { |sezione| posizione(sezione) }

      expect(posizioni).to eq(posizioni.sort)
    end

    it "puts the range selector in the title row of every chart panel" do
      get member_monitoring_server_path(host, tab: "metrics")

      doc = Nokogiri::HTML(response.body)
      panels = doc.css("[data-test^='server-section-']")
      expect(panels).not_to be_empty
      panels.each do |panel|
        expect(panel.at_css("h2 + [data-test='range-selector'], h2 ~ * [data-test='range-selector']")).to be_present, panel["data-test"]
      end
    end
  end
end
