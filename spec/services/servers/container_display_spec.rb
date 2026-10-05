# frozen_string_literal: true

require "rails_helper"

# CYRA-464 — la sezione che risponde a «cosa gira qui» era l'unica dove non si capiva cosa girasse:
# il taglio del testo cadeva dentro il prefisso del registro, ripetuto due volte.
RSpec.describe "Container leggibili", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:server_host, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "alla raccolta" do
    it "toglie il prefisso del registro ripetuto" do
      normalize = Servers::Ingest::Normalize.allocate

      expect(normalize.send(:normalize_image, "registry.esempio.it/registry.esempio.it/org/app")).to eq("registry.esempio.it/org/app")
      expect(normalize.send(:normalize_image, "ghcr.io/ghcr.io/bussolabs/closeyourit")).to eq("ghcr.io/bussolabs/closeyourit")
    end

    it "lascia intatto un indirizzo normale" do
      normalize = Servers::Ingest::Normalize.allocate

      expect(normalize.send(:normalize_image, "postgres:17")).to eq("postgres:17")
      expect(normalize.send(:normalize_image, "registry.x/org/app")).to eq("registry.x/org/app")
      expect(normalize.send(:normalize_image, " ")).to be_nil
    end
  end

  describe "in lettura" do
    it "accorcia il codice nel nome e tiene il nome intero nel tooltip" do
      create(:server_container_sample, host:, name: "closeyourit-web-2f1a9c8e4b7d6a5c3e2f1a9b", image: "registry.x/org/app",
                                       recorded_at: 1.minute.ago)

      get member_monitoring_server_path(host, tab: "workloads")

      cella = Nokogiri::HTML(response.body).at_css('[data-test="server-container-row"] span[title]')
      expect(cella.text).to eq("closeyourit-web-2f1a9c8")
      expect(cella["title"]).to eq("closeyourit-web-2f1a9c8e4b7d6a5c3e2f1a9b")
    end

    it "taglia l'indirizzo a sinistra, lasciando leggibile ciò che identifica il programma" do
      lungo = "registry.esempio.it/organizzazione/sottogruppo/closeyourit-web:v1.2.3"
      create(:server_container_sample, host:, name: "web", image: lungo, recorded_at: 1.minute.ago)

      get member_monitoring_server_path(host, tab: "workloads")

      testo = Nokogiri::HTML(response.body).at_css('[data-test="server-container-row"]').text
      expect(testo).to include("closeyourit-web:v1.2.3")
    end

    it "dice a parole che non c'è un controllo di salute" do
      create(:server_container_sample, host:, name: "web", health: :none, recorded_at: 1.minute.ago)

      get member_monitoring_server_path(host, tab: "workloads")

      testo = Nokogiri::HTML(response.body).at_css('[data-test="server-container-row"]').text
      expect(testo).to include(I18n.t("member.servers.show.health.none"))
      expect(testo).not_to include("none")
    end
  end
end
