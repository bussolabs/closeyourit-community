# frozen_string_literal: true

require "rails_helper"

# CYRA-430 — nel Vault diverse funzioni importanti esistevano ma non si vedevano: la sincronizzazione
# con GitHub, la lettura dei segreti dal proprio computer, lo sblocco della riga per modificarla, lo
# storico con ripristino, la seconda approvazione e la registrazione delle letture. Chi non le trovava
# continuava a copiare i valori a mano, che è esattamente ciò che il prodotto vuole evitare.
RSpec.describe "Member::Vault — «Cosa puoi fare qui» (CYRA-430)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org, name: "Storefront") }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "la pagina delle funzioni" do
    before do
      create(:membership, account: owner, organization: org, role: :owner)
      sign_in(owner)
    end

    it "elenca tutte le funzioni dell'area, ciascuna con un esempio" do
      get member_vault_capabilities_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      chiavi = Member::Vault::CapabilitiesController::FEATURES
      expect(chiavi.size).to eq(7)
      chiavi.each do |chiave|
        blocco = doc.at_css("[data-test='vault-capability-#{chiave.to_s.dasherize}']")
        expect(blocco).to be_present, "manca la funzione #{chiave}"
        expect(blocco.at_css("[data-test='vault-capability-example']")).to be_present,
                                                                          "la funzione #{chiave} non ha un esempio"
      end
    end

    # F1 — a command meant for the terminal comes with its Copy button, like in "Use this secret".
    it "offers Copy on every command block" do
      get member_vault_capabilities_path

      blocks = Capybara.string(response.body).all("[data-test='vault-capability-example'] [data-controller='clipboard']")
      expect(blocks).not_to be_empty
      blocks.each do |block|
        expect(block).to have_css("button[data-action='clipboard#copy']", text: I18n.t("member.secret_usage.copy"))
        expect(block).to have_css("code[data-clipboard-target='source']")
      end
    end

    # Gli esempi citano comandi e file fra backtick: a schermo si leggevano i backtick crudi.
    it "rende come codice i comandi citati negli esempi, senza backtick" do
      get member_vault_capabilities_path

      examples = Nokogiri::HTML(response.body).css("[data-test='vault-capability-example']")
      expect(examples.css("code").map(&:text)).to include("cyi secrets download", ".envrc")
      expect(examples.text).not_to include("`")
    end

    # DoD: «Le funzioni citate sono raggiungibili da un collegamento» — la pagina non spiega soltanto,
    # porta anche dove la funzione si usa.
    it "ogni funzione porta al posto in cui si usa" do
      get member_vault_capabilities_path

      doc = Nokogiri::HTML(response.body)
      Member::Vault::CapabilitiesController::FEATURES.each do |chiave|
        collegamento = doc.at_css("[data-test='vault-capability-link-#{chiave.to_s.dasherize}']")
        expect(collegamento).to be_present, "la funzione #{chiave} non porta da nessuna parte"
        expect(collegamento["href"]).to be_present
      end
    end

    # CYRA-903 — it left the menu: the vault overview lists the features and links each card.
    it "is reached from the vault overview, not from the menu" do
      get member_vault_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='member-nav-vault-capabilities']")).to be_nil
      expect(doc.at_css("[data-test='vault-overview-capabilities-all']")["href"]).to eq(member_vault_capabilities_path)
      expect(doc.at_css("[data-test='vault-overview-capability-cli-read']")["href"])
        .to eq(member_vault_capabilities_path(anchor: "vault-capability-cli-read"))
    end
  end

  # Anti-disclosure: la pagina racconta cosa il prodotto sa fare, ma non offre la porta di una stanza
  # chiusa. Senza il permesso sull'archivio delle letture la funzione resta scritta, il collegamento va
  # dove chi legge può davvero entrare.
  describe "chi non sorveglia i segreti" do
    let(:membro) { create(:account) }

    before do
      create(:membership, account: owner, organization: org, role: :owner)
      create(:membership, account: membro, organization: org, role: :member)
      sign_in(membro)
    end

    it "vede la funzione ma non il collegamento all'archivio delle letture" do
      get member_vault_capabilities_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='vault-capability-read-audit']")).to be_present
      expect(doc.at_css("[data-test='vault-capability-link-read-audit']")["href"]).not_to eq(member_vault_audit_path)
    end
  end
end
