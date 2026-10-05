# frozen_string_literal: true

require "rails_helper"

# CYRA-461 — i valori erano presentati allo stesso modo che arrivassero da dieci secondi o da sei ore
# fa. Il caso pericoloso non è la macchina spenta, che viene segnalata, ma quella che invia a
# singhiozzo: sembra sana e non lo è.
RSpec.describe "Member::Monitoring::Servers — freschezza del dato (CYRA-461)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def host(last_seen:, name: "macchina")
    create(:server_host, organization: org, name: name, status: :up,
                         cpu_pct: 95, mem_pct: 40, disk_pct: 30, last_seen_at: last_seen)
  end

  describe "il modello" do
    it "una macchina che tace da più della soglia è silenziosa, pur restando up" do
      muta = host(last_seen: 10.minutes.ago)

      expect(muta).to be_silent
      expect(muta).to be_status_up
    end

    it "una macchina che ha appena inviato non è silenziosa" do
      viva = host(last_seen: 5.seconds.ago)

      expect(viva).not_to be_silent
    end
  end

  describe "l'elenco" do
    it "sui valori vecchi il colore si spegne e compare la loro età" do
      muta = host(last_seen: 10.minutes.ago, name: "muta")

      get member_monitoring_servers_path

      doc = Nokogiri::HTML(response.body)
      cella = doc.at_css("[data-test='server-cell-cpu-#{muta.id}']")
      expect(cella.text).to include("95")
      expect(cella.at_css("span")["class"]).to include("text-gray-400")
      expect(doc.at_css("[data-test='server-data-age-#{muta.id}']")).to be_present
    end

    it "su una macchina viva il colore resta quello del valore" do
      viva = host(last_seen: 5.seconds.ago, name: "viva")

      get member_monitoring_servers_path

      doc = Nokogiri::HTML(response.body)
      cella = doc.at_css("[data-test='server-cell-cpu-#{viva.id}']")
      expect(cella.at_css("span")["class"]).to include("text-red-600")
      expect(doc.at_css("[data-test='server-data-age-#{viva.id}']")).to be_nil
    end

    it "lo stato dice «silenziosa», che non è né attiva né spenta" do
      host(last_seen: 10.minutes.ago, name: "muta")

      get member_monitoring_servers_path

      expect(response.body).to include(I18n.t("member.servers.status.silent"))
    end
  end
end
