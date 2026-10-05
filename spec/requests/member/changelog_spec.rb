# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Changelog", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account: account, organization: org, role: :member) }

  def sign_in(acct)
    post login_path, params: { email: acct.email, password: "Secret123!" }
  end

  # Solo la lista dello storico: il modale «Novità» della sidebar rende le stesse voci in ogni
  # pagina, e cercarle nel body intero direbbe sempre di sì.
  def lista = Nokogiri::HTML(response.body).at_css("[data-test='changelog-list']").text

  describe "GET /member/changelog" do
    it "risponde con 200" do
      sign_in(account)
      get member_changelog_path
      expect(response).to have_http_status(:ok)
    end

    it "elenca le release del changelog" do
      sign_in(account)
      get member_changelog_path
      expect(response.body).to include("data-test=\"changelog-list\"")
    end

    it "richiede autenticazione" do
      get member_changelog_path
      expect(response).to have_http_status(:redirect)
    end
  end

  # CYRA-445 — la pagina caricava insieme più di cinquanta versioni in una colonna sola: per sapere
  # cosa fosse cambiato su una funzione bisognava scorrere tutta la storia del prodotto.
  describe "consultare lo storico" do
    let(:releases) do
      [
        Changelog::Release.new(
          version: "0.3.0", date: "2026-07-03",
          sections: [
            { label: "Added", items: [ "**Gruppi di controlli**: i siti si raggruppano. [Disponibilità](/member/monitoring/monitors)" ] },
            { label: "Fixed", items: [ "**Etichette storte**: raddrizzate. [Ticket](/member/tickets)" ] }
          ]
        ),
        Changelog::Release.new(
          version: "0.2.0", date: "2026-07-02",
          sections: [ { label: "Changed", items: [ "**Elenco più corto**: si legge prima. [Ticket](/member/tickets)" ] } ]
        ),
        Changelog::Release.new(
          version: "0.1.0", date: "2026-07-01",
          sections: [ { label: "Added", items: [ "**Prima versione**: si comincia." ] } ]
        )
      ]
    end

    before do
      allow(Changelog).to receive(:releases).and_return(releases)
      sign_in(account)
    end

    it "mostra i filtri e la ricerca in cima alla pagina" do
      get member_changelog_path

      expect(response.body).to include("data-test=\"changelog-toolbar\"")
      expect(response.body).to include("data-test=\"changelog-search\"")
      expect(response.body).to include("data-test=\"filter-area\"")
      expect(response.body).to include("data-test=\"filter-kind\"")
    end

    it "filtrando per area mostra solo le voci di quell'area" do
      get member_changelog_path, params: { area: [ "uptime" ] }

      expect(lista).to include("Gruppi di controlli")
      expect(lista).not_to include("Etichette storte")
      expect(lista).not_to include("Elenco più corto")
    end

    it "filtrando per tipo mostra solo le modifiche di quel tipo" do
      get member_changelog_path, params: { kind: [ "fixed" ] }

      expect(lista).to include("Etichette storte")
      expect(lista).not_to include("Gruppi di controlli")
    end

    it "la ricerca cerca dentro il testo delle voci" do
      get member_changelog_path, params: { q: "si legge prima" }

      expect(lista).to include("Elenco più corto")
      expect(lista).not_to include("Gruppi di controlli")
    end

    it "quando i filtri non trovano niente lo dice, invece di mostrare una pagina vuota" do
      get member_changelog_path, params: { q: "parolachenonesiste" }

      expect(response.body).to include("data-test=\"changelog-no-results\"")
    end

    it "mostra il nome che l'area ha nel menu, non quello scritto nel file" do
      get member_changelog_path, params: { area: [ "uptime" ] }

      expect(response.body).to include(">#{I18n.t('member.nav.uptime')}</a>")
      expect(response.body).not_to include(">Disponibilità</a>")
    end
  end

  describe "caricamento un po' alla volta" do
    let(:releases) do
      Array.new(Changelog::Constants::PER_PAGE + 2) do |i|
        number = 30 - i
        Changelog::Release.new(
          version: "0.#{number}.0", date: "2026-07-01",
          sections: [ { label: "Added", items: [ "**Voce #{number}**: testo." ] } ]
        )
      end
    end

    before do
      allow(Changelog).to receive(:releases).and_return(releases)
      sign_in(account)
    end

    it "mostra solo le prime versioni e i controlli per le altre" do
      get member_changelog_path

      expect(lista).to include("Voce 30")
      expect(lista).not_to include("Voce 19")
      expect(response.body).to include("data-test=\"changelog-pagination\"")
    end

    it "la pagina successiva mostra le versioni seguenti" do
      get member_changelog_path, params: { page: 2 }

      expect(lista).to include("Voce 19")
      expect(lista).not_to include("Voce 30")
    end
  end
end
