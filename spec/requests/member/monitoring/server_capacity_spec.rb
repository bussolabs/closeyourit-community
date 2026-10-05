# frozen_string_literal: true

require "rails_helper"

# CYRA-515 — gli avvisi di capacità nominano il mount e il container responsabili, ma chi apriva la
# pagina della macchina per guardarli in faccia non li trovava: gli inode non erano scritti da
# nessuna parte, la tabella dei container non diceva chi stava ciclando, e le connessioni erano
# misurate sul massimo teorico invece che sugli slot davvero utilizzabili — un numero diverso da
# quello dell'avviso appena ricevuto. L'avviso indica il colpevole, la pagina lo deve confermare.
RSpec.describe "Member::Monitoring::Servers — capacità e responsabile (CYRA-515)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def page_for(host, tab:)
    get member_monitoring_server_path(host, tab: tab)
    Nokogiri::HTML(response.body)
  end

  describe "inode per mount" do
    it "il mount che sta finendo gli inode mostra la sua percentuale accanto al disco" do
      host = create(:server_host, :up, organization: org, name: "db-primary")
      create(:server_sample, host: host, organization: org,
                             payload: { "disk" => { "total_gb" => 40, "used_gb" => 10, "inode_pct" => 12 },
                                        "extra_fs" => { "dati" => { "d" => 500, "du" => 100, "ip" => 92 } } })

      riga = page_for(host, tab: "metrics").css("[data-test='server-disk']").find { |node| node.text.include?("dati") }

      expect(riga).to be_present
      expect(riga.text).to include("92")
    end

    it "il disco di sistema porta i propri inode senza inventarli per gli altri" do
      host = create(:server_host, :up, organization: org, name: "web")
      create(:server_sample, host: host, organization: org,
                             payload: { "disk" => { "total_gb" => 40, "used_gb" => 10, "inode_pct" => 88 },
                                        "extra_fs" => { "dati" => { "d" => 500, "du" => 100 } } })

      righe = page_for(host, tab: "metrics").css("[data-test='server-disk']")
      sistema = righe.find { |node| node.text.include?(I18n.t("member.servers.show.disk_root")) }
      dati = righe.find { |node| node.text.include?("dati") }

      expect(sistema.text).to include("88")
      expect(dati.text).not_to include("88")
    end

    it "una macchina che non riporta inode non mostra la voce" do
      host = create(:server_host, :up, organization: org, name: "vm")
      create(:server_sample, host: host, organization: org,
                             payload: { "disk" => { "total_gb" => 40, "used_gb" => 10 } })

      riga = page_for(host, tab: "metrics").at_css("[data-test='server-disk']")

      expect(riga.text).not_to include("inode")
    end
  end

  describe "container in riavvio continuo" do
    def container_host(outage)
      host = create(:server_host, :up, organization: org, name: "app", container_restart_outage: outage)
      recorded_at = 1.minute.ago
      create(:server_container_sample, host: host, name: "app-web", recorded_at: recorded_at)
      create(:server_container_sample, host: host, name: "app-worker", recorded_at: recorded_at)
      host
    end

    it "la riga del container che cicla dichiara quanti riavvii ha fatto" do
      host = container_host("containers" => [ { "name" => "app-web", "restarts" => 5, "oom_killed" => false } ])

      riga = page_for(host, tab: "workloads").css("[data-test='server-container-row']").find { |node| node.text.include?("app-web") }

      expect(riga.at_css("[data-test='server-container-restarts']")).to be_present
      expect(riga.text).to include("5")
    end

    it "il container che non cicla resta pulito" do
      host = container_host("containers" => [ { "name" => "app-web", "restarts" => 5, "oom_killed" => false } ])

      riga = page_for(host, tab: "workloads").css("[data-test='server-container-row']").find { |node| node.text.include?("app-worker") }

      expect(riga.at_css("[data-test='server-container-restarts']")).to be_nil
    end

    it "il container ucciso per memoria esaurita lo dice, che è un'altra causa" do
      host = container_host("containers" => [ { "name" => "app-web", "restarts" => 4, "oom_killed" => true } ])

      riga = page_for(host, tab: "workloads").css("[data-test='server-container-row']").find { |node| node.text.include?("app-web") }

      expect(riga.at_css("[data-test='server-container-oom']")).to be_present
    end

    it "senza riavvii in corso la tabella non cambia" do
      host = container_host({})

      righe = page_for(host, tab: "workloads").css("[data-test='server-container-restarts']")

      expect(righe).to be_empty
    end
  end

  describe "connessioni del database" do
    it "il rapporto è sugli slot utilizzabili, gli stessi che conta l'avviso" do
      host = create(:server_host, :up, organization: org, name: "db",
                                       database_snapshot: { "reachable" => true, "engine" => "postgresql",
                                                            "connections" => { "total" => 80, "max" => 100, "reserved" => 10 } })

      blocco = page_for(host, tab: "hardware").at_css("[data-test='server-database-connections']")

      expect(blocco.text).to include("80 / 90")
    end

    it "gli slot tenuti da parte sono dichiarati, non spariti" do
      host = create(:server_host, :up, organization: org, name: "db",
                                       database_snapshot: { "reachable" => true, "engine" => "postgresql",
                                                            "connections" => { "total" => 80, "max" => 100, "reserved" => 10 } })

      blocco = page_for(host, tab: "hardware").at_css("[data-test='server-database-connections']")

      expect(blocco.at_css("[data-test='server-database-reserved']")).to be_present
      expect(blocco.text).to include("10")
    end

    it "senza slot riservati il massimo resta il massimo" do
      host = create(:server_host, :up, organization: org, name: "db",
                                       database_snapshot: { "reachable" => true, "engine" => "postgresql",
                                                            "connections" => { "total" => 40, "max" => 100 } })

      blocco = page_for(host, tab: "hardware").at_css("[data-test='server-database-connections']")

      expect(blocco.text).to include("40 / 100")
      expect(blocco.at_css("[data-test='server-database-reserved']")).to be_nil
    end
  end
end
