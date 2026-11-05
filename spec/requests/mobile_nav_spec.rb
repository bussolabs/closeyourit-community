# frozen_string_literal: true

require "rails_helper"

# Contratto del drawer di navigazione mobile (P1 responsive): sotto il breakpoint md
# la sidebar è off-canvas e raggiungibile via hamburger. Qui asseriamo il MARKUP
# (hamburger + aside drawer + overlay + wiring Stimulus) — rack_test non ha JS, il
# comportamento di apertura/chiusura è verificato nel browser a 390px.
RSpec.describe "Navigazione mobile (drawer)", type: :request do
  # CYRA-170: il god in layout Valhalla passa dal 2FA (attivato al volo + secondo fattore); il membro
  # (non-god) del layout member resta invariato.
  def sign_in(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  describe "layout member" do
    let(:org) { create(:organization) }
    let(:owner) { create(:account) }

    before do
      create(:membership, account: owner, organization: org, role: :owner)
      sign_in(owner)
      get root_path
    end

    it "risponde 200 col wrapper controllato da ui--mobile-nav" do
      expect(response).to have_http_status(:ok)
      # CYRA-28 ha aggiunto il controller keyboard universale al wrapper member → multi-controller.
      expect(response.body).to include('data-controller="ui--mobile-nav keyboard"')
    end

    it "espone l'hamburger md:hidden con i data attribute Stimulus" do
      expect(response.body).to include('data-test="member-nav-toggle"')
      expect(response.body).to include('data-ui--mobile-nav-target="toggle"')
      expect(response.body).to include('aria-controls="member-sidebar"')
    end

    it "la sidebar è un pannello off-canvas (drawer) con fallback desktop" do
      expect(response.body).to include('data-ui--mobile-nav-target="panel"')
      expect(response.body).to include('id="member-sidebar"')
      expect(response.body).to include("-translate-x-full")
      expect(response.body).to include("md:translate-x-0")

      # CYRA-663 — lo stato di partenza NON arriva piu' dal server. Con `inert` nel markup, una
      # sidebar desktop restava visibile e morta finche' Stimulus non partiva; in Valhalla non
      # c'e' nemmeno la barra in basso come alternativa. Fuori dal drawer la nasconde il CSS,
      # che non dipende da JavaScript.
      sidebar = Nokogiri::HTML(response.body).at_css("#member-sidebar")
      expect(sidebar["inert"]).to be_nil
      expect(sidebar["aria-hidden"]).to be_nil
      expect(sidebar["class"]).to include("max-md:invisible")
    end

    it "espone l'overlay scrim che chiude il drawer al click" do
      expect(response.body).to include('data-ui--mobile-nav-target="overlay"')
      expect(response.body).to include("ui--mobile-nav#close")
    end

    it "permette di saltare la navigazione e raggiungere direttamente il contenuto" do
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css("[data-test='skip-link']")["href"]).to eq("#main-content")
      expect(doc.at_css("main#main-content")).to be_present
    end
  end

  describe "layout valhalla" do
    before do
      sign_in(create(:account, god: true))
      get valhalla_root_path
    end

    it "risponde 200 col wrapper controllato da ui--mobile-nav" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="ui--mobile-nav"')
    end

    it "espone hamburger + drawer + overlay col wiring Stimulus" do
      expect(response.body).to include('data-test="valhalla-nav-toggle"')
      expect(response.body).to include('aria-controls="valhalla-sidebar"')
      expect(response.body).to include('data-ui--mobile-nav-target="panel"')
      expect(response.body).to include('id="valhalla-sidebar"')
      expect(response.body).to include("-translate-x-full")
      expect(response.body).to include('data-ui--mobile-nav-target="overlay"')

      # CYRA-663 — lo stato di partenza NON arriva piu' dal server. Con `inert` nel markup, una
      # sidebar desktop restava visibile e morta finche' Stimulus non partiva; in Valhalla non
      # c'e' nemmeno la barra in basso come alternativa. Fuori dal drawer la nasconde il CSS,
      # che non dipende da JavaScript.
      sidebar = Nokogiri::HTML(response.body).at_css("#valhalla-sidebar")
      expect(sidebar["inert"]).to be_nil
      expect(sidebar["aria-hidden"]).to be_nil
      expect(sidebar["class"]).to include("max-md:invisible")
    end

    it "permette di saltare il drawer e raggiungere direttamente il contenuto" do
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css("[data-test='skip-link']")["href"]).to eq("#main-content")
      expect(doc.at_css("main#main-content")).to be_present
    end
  end
end
