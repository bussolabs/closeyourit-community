# frozen_string_literal: true

require "rails_helper"

# CYRA-819 — Il dettaglio di un ticket su uno schermo da 390 px. Stato e priorità vivono nel pannello
# Dettagli (CYRA-65), che sta nella colonna destra: sotto lg la griglia impila, la colonna destra
# finisce SOTTO il corpo del ticket e su due ticket veri lo stato è stato misurato a 2035 px e a
# 2125 px dalla cima della pagina — mentre i comandi (Segui, Prendi in carico, il menu) stanno poco
# sopra i 300. Per sapere a che punto è il lavoro prima di intervenire bisognava scorrere fino in
# fondo e tornare su.
#
# PERCHÉ NEL BROWSER E NON NEL DOM: «leggibile senza attraversare il corpo» è una distanza in pixel,
# e la distanza dipende da quanto è lungo il ticket e da dove la griglia impila le colonne. Nel DOM
# si legge l'ordine degli elementi, non quanto dista il secondo dal primo.
RSpec.describe "Dettaglio ticket su schermo stretto", type: :system, js: true do
  # Il foglio Tailwind è un ARTEFATTO costruito, non un sorgente: senza, il browser rende la pagina
  # priva di ogni classe e `lg:hidden` non spegne niente — la prova passerebbe misurando una pagina
  # che nella realtà è un'altra. Se la costruzione non riesce ma il foglio c'è già (in CI può
  # arrivare da un passo di precompilazione) si prosegue con quello: a dire se è arrivato davvero al
  # browser è l'asserzione su `display: none` a schermo largo.
  FOGLIO_TAILWIND_TICKET = Rails.root.join("app/assets/builds/tailwind.css")

  before(:context) do
    costruito = system("bin/rails tailwindcss:build", out: File::NULL, err: File::NULL)
    raise "tailwindcss:build fallito e #{FOGLIO_TAILWIND_TICKET} non esiste" unless costruito || FOGLIO_TAILWIND_TICKET.exist?
  end

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STOR") }
  let(:status) { create(:ticket_status, organization: org, code: "in_progress", label: "In lavorazione", color: "amber") }
  let(:priority) { create(:ticket_priority, organization: org, code: "high", label: "Alta", color: "red") }

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  # Un ticket vero è lungo: descrizione, scenari, criteri. È la lunghezza del corpo a spingere in
  # fondo il pannello Dettagli — con un ticket di due righe il guasto non si riprodurrebbe.
  def ticket_lungo
    create(:ticket, organization: org, project: project, status: status, priority: priority,
                    title: "Dal telefono lo stato del ticket si trova soltanto dopo più schermate",
                    description: ([ "Il corpo di un ticket vero occupa parecchie schermate: " \
                                   "descrizione, contesto, ipotesi, rischi e criteri di accettazione." ] * 30).join("\n\n"))
  end

  # 390×844 è la misura del telefono su cui il guasto è stato misurato. `resize_to` NON basta: Chrome
  # ha una larghezza minima di finestra che lascia la pagina a ~470 px, dove la griglia si comporta
  # già in altro modo. L'emulazione del dispositivo è l'unico modo di avere davvero 390 px.
  def emula_telefono(larghezza: 390)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: larghezza, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  # L'emulazione è del BROWSER, che resta acceso per tutto il processo: non toglierla lascerebbe ogni
  # esempio successivo su uno schermo da telefono (stessa trappola del resize in spec/support/js_system.rb).
  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.respond_to?(:browser)
  end

  # Distanza dalla cima del DOCUMENTO (non della finestra): è quella che dice quanto si deve scorrere.
  def distanza_dalla_cima(test_id)
    page.evaluate_script(<<~JS)
      (() => {
        const e = document.querySelector("[data-test='#{test_id}']");
        return e ? e.getBoundingClientRect().top + window.scrollY : null;
      })()
    JS
  end

  describe "a 390 px, su un ticket lungo" do
    before do
      ticket_lungo
      sign_in_as(owner_account)
      emula_telefono
      visit member_ticket_path(Ticketing::Ticket.last)
      expect(page).to have_css("[data-test='member-ticket']")
    end

    it "stato e priorità si leggono nella prima schermata" do
      expect(distanza_dalla_cima("ticket-mobile-summary")).to be < 844
    end

    it "il riepilogo precede i comandi, che erano l'unica cosa visibile in cima" do
      expect(distanza_dalla_cima("ticket-mobile-summary"))
        .to be < distanza_dalla_cima("page-header-actions")
    end

    # La misura del guasto: senza riepilogo, per leggere lo stato si arrivava fin qui.
    it "il pannello Dettagli resta lontano: è il viaggio che il riepilogo evita" do
      expect(distanza_dalla_cima("ticket-details")).to be > 1500
    end

    it "mostra la parola dello stato e quella della priorità" do
      within_test("ticket-mobile-summary") do
        expect(page).to have_text(status.display_label)
        expect(page).to have_text(priority.display_label)
      end
    end
  end

  # Da lg in su la scelta di CYRA-65 resta intatta: il riepilogo è spento e stato e priorità stanno
  # nel pannello Dettagli della colonna destra, affiancata al corpo. `display: none` prova anche che
  # il foglio di stile è arrivato al browser: senza, ogni misura di questo file sarebbe priva di senso.
  it "su schermo largo il riepilogo è spento e il pannello Dettagli resta in colonna" do
    ticket_lungo
    sign_in_as(owner_account)
    visit member_ticket_path(Ticketing::Ticket.last)
    expect(page).to have_css("[data-test='ticket-details']", visible: :all)

    resa = page.evaluate_script(<<~JS)
      (() => {
        const r = document.querySelector("[data-test='ticket-mobile-summary']");
        const d = document.querySelector("[data-test='ticket-details']").getBoundingClientRect();
        const c = document.querySelector("[data-test='ticket-tabs']").getBoundingClientRect();
        return [getComputedStyle(r).display, d.left > c.left, d.top < c.bottom + 400];
      })()
    JS

    expect(resa[0]).to eq("none")
    expect(resa[1]).to be(true)
    expect(resa[2]).to be(true)
  end
end
