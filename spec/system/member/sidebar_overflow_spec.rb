# frozen_string_literal: true

require "rails_helper"

# CYRA-585 — il menu laterale è più alto della finestra e le voci in fondo restano sotto il bordo,
# senza che niente lo dica: la barra di scorrimento è nascosta di proposito (`scrollbar-none`) e su
# macOS sarebbe comunque invisibile a riposo. Chi cerca i Secret o i Membri conclude che non
# esistono. Qui si tiene fermo il segnale: quando c'è altro sotto — e SOLO allora — il fondo del
# menu lo dichiara.
RSpec.describe "Member sidebar — il menu che continua sotto il bordo", type: :system do
  let(:org) { create(:organization) }

  def account_with(role)
    account = create(:account)
    create(:membership, account: account, organization: org, role: role)
    account
  end

  describe "aggancio nel markup" do
    before { driven_by(:rack_test) }

    def sign_in_as(account)
      visit login_path
      fill_test "login-email", with: account.email
      fill_test "login-password", with: "Secret123!"
      click_on_test "login-submit"
    end

    it "il menu dichiara il controllo che misura quanto resta fuori" do
      sign_in_as(account_with(:owner))
      visit root_path

      expect(find("[data-test='member-nav']", visible: :all)["data-controller"].to_s).to include("ui--scroll-hint")
    end

    # Senza JS il segnale non può sapere se c'è davvero altro sotto: parte spento, così non promette
    # un seguito che magari non c'è. È il JS ad accenderlo dopo la misura.
    it "il segnale nasce spento e vive dentro il menu, non sotto il menu" do
      sign_in_as(account_with(:owner))
      visit root_path

      expect(page).to have_css("[data-test='member-nav'] [data-test='member-nav-more']", visible: :all)
      expect(page).to have_no_css("[data-test='member-nav-more']", visible: :visible)
    end
  end

  describe "comportamento nel browser", :js do
    # Il taglio esiste solo se il menu ha davvero le misure del foglio di stile compilato: senza,
    # niente scorre e la misura non direbbe niente sul difetto. Il build CSS non fa parte del setup
    # dei test, quindi qui si salta invece di diventare rossi per il motivo sbagliato — stessa regola
    # di `spec/system/ui/tooltip_position_spec.rb`.
    before do
      css = Rails.root.join("app/assets/builds/tailwind.css")
      skip "CSS Tailwind non compilato (bin/rails tailwindcss:build)" unless css.exist? && css.size.positive?
    end

    # Finestra bassa: è la condizione del ticket (misurato a 907 px, in dev anche 700), qui esasperata
    # perché il taglio ci sia con qualsiasi insieme di permessi.
    def finestra(altezza)
      page.driver.browser.manage.window.resize_to(1280, altezza)
    end

    def segnale_visibile?
      page.has_css?("[data-test='member-nav-more']", visible: :visible, wait: 4)
    end

    def scorri_il_menu_in_fondo
      page.execute_script(<<~JS)
        const nav = document.querySelector("[data-test='member-nav']")
        nav.scrollTop = nav.scrollHeight
      JS
    end

    it "quando le voci non ci stanno, il fondo del menu dice che continua" do
      finestra(420)
      sign_in_as(account_with(:owner))
      visit root_path

      expect(page).to have_css("[data-test='member-nav']")
      expect(segnale_visibile?).to be(true), "il menu è tagliato ma niente lo segnala"
    end

    it "arrivati in fondo il segnale si spegne, e risalendo torna" do
      finestra(420)
      sign_in_as(account_with(:owner))
      visit root_path
      expect(segnale_visibile?).to be(true)

      scorri_il_menu_in_fondo

      expect(page).to have_no_css("[data-test='member-nav-more']", visible: :visible)

      page.execute_script("document.querySelector(\"[data-test='member-nav']\").scrollTop = 0")

      expect(segnale_visibile?).to be(true)
    end

    # L'altra metà della regola: un segnale sempre acceso è rumore, non informazione. La finestra si
    # apre su misura del menu con tutti i gruppi chiusi — così la prova non dipende da quante voci
    # dipinge il ruolo, né da quanto è alto lo schermo di chi la esegue.
    def chiudi_i_gruppi_e_allarga_la_finestra
      page.execute_script("document.querySelectorAll(\"[data-test='member-nav'] [id^='member-nav-items-']\").forEach((g) => { g.hidden = true })")
      alto = page.evaluate_script("document.querySelector(\"[data-test='member-nav']\").scrollHeight")
      # Room for brand, footer (Guides, version, compact toggle: CYRA-903) and the browser chrome.
      finestra(alto + 450)
    end

    it "quando le voci ci stanno tutte, il segnale resta spento" do
      finestra(420)
      sign_in_as(account_with(:owner))
      visit root_path
      expect(page).to have_css("[data-test='member-nav']")

      chiudi_i_gruppi_e_allarga_la_finestra

      expect(page).to have_no_css("[data-test='member-nav-more']", visible: :visible)
    end

    # Aprire un gruppo allunga il menu senza cambiare la finestra: se si misurasse solo al resize, il
    # segnale resterebbe spento proprio quando il taglio nasce.
    #
    # Se ne apre UNO, e uno dei più lunghi: da CYRA-582 il menu è una fisarmonica — aprirli tutti
    # insieme non è più possibile, e chiedere `open = true` su tutti ne lascerebbe aperto uno solo,
    # scelto dall'ordine del DOM invece che dal test.
    it "aprire un gruppo accende il segnale, anche a finestra ferma" do
      finestra(420)
      sign_in_as(account_with(:owner))
      visit root_path
      expect(page).to have_css("[data-test='member-nav']")

      chiudi_i_gruppi_e_allarga_la_finestra
      expect(page).to have_no_css("[data-test='member-nav-more']", visible: :visible)

      find("[data-test='member-nav-toggle-infrastructure']").click

      expect(segnale_visibile?).to be(true), "il menu si è allungato ma il segnale è rimasto spento"
    end
  end
end
