# frozen_string_literal: true

require "rails_helper"

# CYRA-568 — i due scenari del ticket sul campo, in una pagina vera e con la lingua italiana scelta
# dall'account: un conteggio sopra il migliaio scritto all'italiana e SEMPRE nello stesso modo
# dentro la stessa schermata, e un elenco dentro una frase unito da una «e».
RSpec.describe "Numeri ed elenchi nelle pagine", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account, locale: "it") }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "un conteggio sopra il migliaio" do
    # Il caso osservato: la finestra che apre il ticket scriveva «2,841» e «2,113», l'elenco «2841».
    let!(:group) do
      create(:error_group, project:, title: "RuntimeError: boom", events_count: 2841, users_count: 2113)
    end

    it "l'elenco lo scrive con le migliaia separate dal punto" do
      sign_in(owner)
      get member_monitoring_error_groups_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='error-group-events-#{group.id}']").text.strip).to eq("2.841")
      expect(doc.at_css("[data-test='error-group-users-#{group.id}']").text.strip).to eq("2.113")
    end

    it "la scheda e la finestra che apre il ticket scrivono lo stesso numero nello stesso modo" do
      sign_in(owner)
      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      chip = doc.at_css("[data-test='error-events']").text
      finestra = doc.at_css("[data-test='promote-preview-counts']").text
      expect(chip).to include("2.841")
      expect(finestra).to include("2.841").and include("2.113")
      # Né la forma inglese, né quella senza separatore: sono le due che convivevano in pagina.
      # Il confronto sta sui due frammenti e non su tutta la risposta: gli identificativi in
      # pagina sono casuali e prima o poi uno conterrebbe quelle cifre per conto suo.
      [ chip, finestra ].each do |testo|
        expect(testo).not_to include("2,841")
        expect(testo).not_to include("2841")
      end
    end
  end

  describe "un elenco dentro una frase" do
    it "unisce le due colonne nascoste con una e, non con and" do
      sign_in(owner)
      create(:ticket, organization: org, project:, due_at: nil, assignee: nil)

      get list_member_tickets_path

      doc = Nokogiri::HTML(response.body)
      frase = doc.at_css("[data-test='tickets-hidden-columns']").text
      expect(frase).to include("Scadenza e Assegnatario")
      expect(frase).not_to include(" and ")
    end
  end
end
