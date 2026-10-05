# frozen_string_literal: true

require "rails_helper"

# CYRA-459 — non c'era nessun pulsante per collegare una macchina nuova (le istruzioni stavano dietro
# un pulsante che nominava un oggetto, «Token», invece di un'intenzione), e una volta trovate dicevano
# di sostituire il segreto «qui sopra» due righe sotto l'avviso che quel segreto si vede una volta sola.
RSpec.describe "Member::Monitoring — collegare una macchina (CYRA-459)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "l'elenco ha un comando in evidenza che dice cosa fa" do
    get member_monitoring_servers_path

    cta = Nokogiri::HTML(response.body).at_css("[data-test='servers-connect']")
    expect(cta).to be_present
    expect(cta.text).to include(I18n.t("member.servers.connect_cta"))
  end

  it "le istruzioni non rimandano più a un segreto che non è più visibile" do
    get member_monitoring_server_tokens_path

    lead = I18n.t("member.servers.tokens.snippet_lead")
    expect(lead).not_to include("qui sopra") if I18n.locale == :it
    expect(response.body).to include(lead)
  end

  it "le istruzioni si copiano e coprono anche le macchine che ospitano i database" do
    get member_monitoring_server_tokens_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='server-tokens-copy']")).to be_present
    expect(doc.at_css("[data-test='server-tokens-database-host']")).to be_present
  end

  it "dalla pagina si raggiunge la guida dedicata" do
    get member_monitoring_server_tokens_path

    guida = Nokogiri::HTML(response.body).at_css("[data-test='server-tokens-guide']")
    expect(guida["href"]).to eq(member_guides_servers_path)
  end

  describe "sapere se ha funzionato" do
    it "senza nessuna macchina arrivata lo dice, invece di lasciare nel dubbio" do
      get member_monitoring_server_tokens_path

      stato = Nokogiri::HTML(response.body).at_css("[data-test='server-tokens-status']")
      expect(stato.text).to include(I18n.t("member.servers.tokens.status_waiting"))
    end

    it "quando le macchine sono arrivate lo dice" do
      create(:server_host, organization: org, status: :up)

      get member_monitoring_server_tokens_path

      stato = Nokogiri::HTML(response.body).at_css("[data-test='server-tokens-status']")
      expect(stato.text).to include("1")
    end
  end
end
