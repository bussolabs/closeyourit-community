# frozen_string_literal: true

require "rails_helper"

# Contratto della bottom navbar mobile (area member). Le AZIONI QUOTIDIANE (liste, notifiche,
# aggiunta rapida, chat, menu) vivono in un UNICO nodo <nav data-test="member-bottom-nav"> che resta figlio di
# <header> nel DOM (nessun id/stream Turbo duplicato) e si riposiziona via CSS: fixed bottom-0 su
# mobile, md:static su desktop. L'ingresso al pannello god (Valhalla) NON è più qui (CYRA-331): vive
# nel menu del profilo. In alto restano solo org-switcher e presence. Il PROFILO invece:
# su desktop è nell'header (user-menu, hidden md:flex), su MOBILE è nel drawer laterale (aside) con
# le sue voci Account/Esci. Qui asseriamo la STRUTTURA DOM + le classi responsive; il riposizionamento
# visuale è verificato nel browser a 390px/1280px.
RSpec.describe "Member bottom nav (mobile)", type: :request do
  let(:doc) { Nokogiri::HTML(response.body) }
  let(:nav) { doc.at_css("nav[data-test='member-bottom-nav']") }

  describe "owner con organizzazione" do
    let(:organization) { create(:organization, name: "Demo") }
    let(:owner) { create(:account, name: "Olivia Holt") }

    before do
      create(:membership, account: owner, organization: organization, role: :owner)
      post login_path, params: { email: owner.email, password: "Secret123!" }
      get root_path
    end

    it "il nav bottom vive dentro <header> con le classi di reflow responsive" do
      expect(doc.at_css("header nav[data-test='member-bottom-nav']")).to be_present
      expect(nav["class"]).to include("fixed")
      expect(nav["class"]).to include("bottom-0")
      expect(nav["class"]).to include("md:static")
      # On desktop the bar sits on the page background: no white strip behind the buttons (CYRA-898).
      expect(nav["class"]).to include("md:bg-transparent")
    end

    it "le azioni stanno nel nav bottom nell'ordine mobile approvato" do
      azioni = %w[member-nav-todos notification-bell member-nav-quick-add member-nav-chat member-nav-toggle]
      azioni.each { |azione| expect(nav.at_css("[data-test='#{azione}']")).to be_present }

      ordine = nav.css("[data-test]").filter_map { |nodo| nodo["data-test"] }.select { |id| azioni.include?(id) }
      expect(ordine).to eq(azioni)
    end

    it "su desktop le azioni applicative formano un unico button group segmentato" do
      expect(nav.at_css("[data-test='global-search-trigger-desktop']")).to be_present
      expect(nav.at_css("[data-test='member-nav-chat']")["class"]).to include("md:border-l")
      expect(nav.at_css("[data-test='notification-bell']")["class"]).to include("md:border-l")
    end

    it "il menu mobile è l'ultima azione e non ha un controllo desktop" do
      toggle = nav.at_css("[data-test='member-nav-toggle']")

      expect(toggle["class"]).to include("md:hidden")
      expect(toggle["class"]).to include("order-5")
    end

    it "l'hamburger nel nav bottom pilota il drawer (wiring Stimulus invariato)" do
      toggle = nav.at_css("[data-test='member-nav-toggle']")

      expect(toggle["data-ui--mobile-nav-target"]).to eq("toggle")
      expect(toggle["aria-controls"]).to eq("member-sidebar")
    end

    it "presence e lente mobile restano in alto, MAI nel nav bottom" do
      header = doc.at_css("header")
      %w[member-org-switcher presence global-search-trigger-mobile].each do |in_alto|
        expect(header.at_css("[data-test='#{in_alto}']")).to be_present
        expect(nav.at_css("[data-test='#{in_alto}']")).to be_nil
      end
    end

    it "il profilo NON è nella bottom bar: user-menu desktop nell'header (hidden md:flex)" do
      expect(nav.at_css("[data-test='member-menu-account']")).to be_nil
      expect(nav.at_css("[data-test='member-menu-logout']")).to be_nil

      # Il trigger user-menu desktop esiste ma è avvolto in un contenitore hidden md:flex.
      contenitore = doc.at_css("[data-test='member-user-menu']")
                       .ancestors("div").find { |nodo| nodo["class"].to_s.include?("md:flex") }
      expect(contenitore["class"]).to include("hidden")
    end

    it "su mobile organizzazione e profilo vivono nel drawer laterale" do
      profilo = doc.at_css("aside [data-test='member-menu-profile']")

      expect(profilo["class"]).to include("md:hidden")
      expect(profilo.at_css("[data-test='member-menu-org-switcher']")).to be_present
      expect(profilo.at_css("[data-test='member-menu-name']").text).to include("Olivia Holt")
      expect(profilo.at_css("[data-test='member-menu-account']")).to be_present
      expect(profilo.at_css("[data-test='member-menu-logout']")).to be_present
    end

    it "il badge notifiche resta unico nella pagina (nessun id duplicato)" do
      expect(doc.css("#alerting_notification_badge").size).to eq(1)
    end
  end

  describe "ingresso Valhalla (god)" do
    it "NON è tra le icone del nav bottom: vive nel menu del profilo (CYRA-331)" do
      sign_in_god(create(:account, name: "Zeus", god: true))
      get root_path

      expect(nav.at_css("[data-test='member-nav-valhalla']")).to be_nil
      expect(doc.css("[data-test^='global-search-trigger-']")).to be_empty
      expect(doc.at_css("[data-test='global-search-dialog']")).to be_nil

      menu_profilo = doc.at_css("[data-test='member-user-menu-wrapper']")
      expect(menu_profilo.at_css("[data-test='member-nav-valhalla']")).to be_present
    end

    it "un non-god non vede alcun ingresso Valhalla" do
      account = create(:account, god: false)
      organization = create(:organization, name: "Demo Org")
      create(:membership, account: account, organization: organization, role: :member)
      post login_path, params: { email: account.email, password: "Secret123!" }

      get root_path

      expect(doc.at_css("[data-test='member-nav-valhalla']")).to be_nil
    end
  end
end
