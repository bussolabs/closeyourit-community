# frozen_string_literal: true

require "rails_helper"

# CYRA-456 — l'elenco mostrava tutte le macchine allo stesso modo, in ordine alfabetico: una quasi
# piena sembrava identica a una scarica, e il riepilogo diceva solo che nessuna era spenta. A
# diciassette righe si sopravvive a occhio, a quaranta no.
RSpec.describe "Member::Monitoring::Servers — chi sta soffrendo (CYRA-456)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:alerting_rule, organization: org, event_type: :server_disk, threshold: 80)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def host(name:, disk: nil, cpu: nil, mem: nil)
    create(:server_host, organization: org, name: name, status: :up,
                         disk_pct: disk, cpu_pct: cpu, mem_pct: mem)
  end

  it "le macchine in difficoltà stanno in cima, non in ordine alfabetico" do
    allow_n_plus_one do
      host(name: "alfa-tranquilla", disk: 10)
      host(name: "zeta-al-limite", disk: 95)
    end

    get member_monitoring_servers_path

    righe = Nokogiri::HTML(response.body).css("[data-test='server-row'], tbody tr").map(&:text)
    expect(righe.first).to include("zeta-al-limite")
  end

  it "la cella sopra soglia si accende, non solo il numero" do
    piena = host(name: "piena", disk: 95)

    get member_monitoring_servers_path

    cella = Nokogiri::HTML(response.body).at_css("[data-test='server-cell-disk-#{piena.id}']")
    expect(cella["class"]).to include("bg-rose-50")
  end

  it "una macchina tranquilla resta neutra" do
    calma = host(name: "calma", disk: 12)

    get member_monitoring_servers_path

    cella = Nokogiri::HTML(response.body).at_css("[data-test='server-cell-disk-#{calma.id}']")
    expect(cella["class"]).not_to include("bg-rose-50")
    expect(cella["class"]).not_to include("bg-amber-50")
  end

  it "il riepilogo in cima conta chi è sopra soglia" do
    allow_n_plus_one do
      host(name: "piena-1", disk: 95)
      host(name: "piena-2", disk: 88)
      host(name: "calma", disk: 10)
    end

    get member_monitoring_servers_path

    chip = Nokogiri::HTML(response.body).at_css("[data-test='stat-over-disk']")
    expect(chip).to be_present
    expect(chip.text).to include("2")
  end

  it "senza nessuno sopra soglia la chip non compare: tre zeri fissi insegnano a non leggere" do
    host(name: "calma", disk: 10)

    get member_monitoring_servers_path

    expect(Nokogiri::HTML(response.body).at_css("[data-test='stat-over-disk']")).to be_nil
  end

  it "l'ordine alfabetico resta a un clic" do
    allow_n_plus_one do
      host(name: "alfa", disk: 10)
      host(name: "zeta", disk: 95)
    end

    get member_monitoring_servers_path(sort: "host")

    righe = Nokogiri::HTML(response.body).css("tbody tr").map(&:text)
    expect(righe.first).to include("alfa")
  end
end
