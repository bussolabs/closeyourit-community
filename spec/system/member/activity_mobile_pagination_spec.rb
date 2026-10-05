# frozen_string_literal: true

require "rails_helper"

# CYRA-839 — Il piede di paginazione sul telefono. In fondo al Registro attività riepilogo, scelta
# delle righe e pulsanti delle pagine stavano su una riga sola: a 390 px la pagina diventava larga
# 412 e il pulsante «Successivo» finiva quasi tutto oltre il bordo destro. Per raggiungerlo si
# trascinava lateralmente TUTTA la pagina, anche dopo aver già scorso la tabella nel suo contenitore.
#
# PERCHÉ NEL BROWSER E NON NEL DOM: «va a capo» e «sta dentro lo schermo» sono misure, non classi.
# Il component spec legge le classi; qui si misura in pixel, alla larghezza vera del telefono.
RSpec.describe "Paginazione del Registro attività su schermo stretto", type: :system, js: true do
  # Il foglio Tailwind è un ARTEFATTO costruito: senza, il browser rende la pagina senza una sola
  # classe e ogni misura diventa finta (vedi logs_mobile_layout_spec.rb).
  FOGLIO_TAILWIND_PAGINAZIONE = Rails.root.join("app/assets/builds/tailwind.css")

  before(:context) do
    costruito = system("bin/rails tailwindcss:build", out: File::NULL, err: File::NULL)
    raise "tailwindcss:build fallito e #{FOGLIO_TAILWIND_PAGINAZIONE} non esiste" unless costruito || FOGLIO_TAILWIND_PAGINAZIONE.exist?
  end

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STOR") }

  before { Types::InstallDefaults.call(organization: org) }

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  # Un totale a QUATTRO cifre (il ticket lo chiede: «1–10 di 1.005» è più largo di «1–10 di 30»).
  # In blocco, non uno alla volta: mille factory costerebbero un minuto per esempio.
  def crea_eventi(quanti)
    adesso = Time.current
    righe = Array.new(quanti) do |i|
      { organization_id: org.id, subject_type: "Projects::Project", subject_id: project.id,
        action: "created", actor_name: "Ada", data: {},
        created_at: adesso - i.minutes, updated_at: adesso - i.minutes }
    end
    Activity::Event.insert_all(righe)
  end

  # 390×844: la misura del telefono su cui il guasto è stato misurato. `resize_to` non basta
  # (Chrome ha una larghezza minima di finestra sopra i 390 px): serve l'emulazione del dispositivo.
  def emula_telefono(larghezza: 390)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: larghezza, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.respond_to?(:browser)
  end

  def larghezza_pagina
    page.evaluate_script("[document.querySelector('main').scrollWidth, document.querySelector('main').clientWidth]")
  end

  def bordo_destro(test_id)
    page.evaluate_script("document.querySelector(\"[data-test='#{test_id}']\").getBoundingClientRect().right")
  end

  def bordo_alto(selettore)
    page.evaluate_script("document.querySelector(\"#{selettore}\").getBoundingClientRect().top")
  end

  def nessun_overflow
    scroll_width, client_width = larghezza_pagina
    expect(client_width).to eq(390)
    expect(scroll_width).to eq(client_width)
  end

  describe "a 390 px, con 1.005 voci da sfogliare" do
    before do
      crea_eventi(1005)
      sign_in_as(owner_account)
      emula_telefono
    end

    it "prima pagina: pulsanti e scelta righe dentro lo schermo, sotto il riepilogo" do
      visit member_activity_path(per: 12)
      expect(page).to have_css("[data-test='activity-pagination']")

      nessun_overflow
      expect(page).to have_css("[data-test='activity-pagination']", text: "1–12 of 1,005")
      expect(bordo_destro("pagination-next")).to be <= 390
      expect(bordo_destro("pagination-per-100")).to be <= 390
      # Impilati: i pulsanti stanno SOTTO il riepilogo, non accanto.
      expect(bordo_alto("[data-test='pagination-controls']")).to be > bordo_alto("[data-test='pagination-summary']")
    end

    it "pagina intermedia: prima, ultima, corrente e frecce tutte dentro lo schermo" do
      visit member_activity_path(per: 12, page: 50)
      expect(page).to have_css("[data-test='activity-pagination']")

      nessun_overflow
      expect(page).to have_css("span[aria-current='page']", text: "50")
      expect(page).to have_link("1")
      expect(page).to have_link("84")
      expect(bordo_destro("pagination-prev")).to be <= 390
      expect(bordo_destro("pagination-next")).to be <= 390
      expect(page.evaluate_script("document.querySelector(\"[data-test='pagination-controls']\").getBoundingClientRect().right")).to be <= 390
      # Sulla stessa riga: la freccia «Successivo» non va a capo da sola sotto le altre.
      expect(bordo_alto("[data-test='pagination-next']")).to eq(bordo_alto("[data-test='pagination-prev']"))
    end

    it "ultima pagina: il piede resta dentro lo schermo e la freccia indietro è raggiungibile" do
      visit member_activity_path(per: 12, page: 84)
      expect(page).to have_css("[data-test='activity-pagination']")

      nessun_overflow
      expect(page).to have_css("[data-test='activity-pagination']", text: "997–1,005 of 1,005")
      expect(page).to have_no_css("[data-test='pagination-next']")
      expect(bordo_destro("pagination-prev")).to be <= 390
    end

    it "sfogliando dal telefono il filtro resta e la pagina cambia" do
      visit member_activity_path(per: 12, source: "work")
      expect(page).to have_css("[data-test='pagination-next']")

      find("[data-test='pagination-next']").click

      expect(page).to have_css("span[aria-current='page']", text: "2")
      expect(page).to have_current_path(/source=work/)
      nessun_overflow
    end
  end

  it "a 390 px con una sola pagina resta il riepilogo, senza pulsanti né overflow" do
    crea_eventi(3)
    sign_in_as(owner_account)
    emula_telefono
    visit member_activity_path

    expect(page).to have_css("[data-test='activity-pagination']", text: "1–3 of 3")
    expect(page).to have_no_css("[data-test='pagination-next']")
    expect(page).to have_no_css("[data-test='pagination-per']")
    nessun_overflow
  end

  it "a 390 px senza risultati la pagina non è più larga dello schermo" do
    crea_eventi(3)
    sign_in_as(owner_account)
    emula_telefono
    visit member_activity_path(from: 1.day.from_now.iso8601)

    expect(page).to have_css("[data-test='activity-no-match']")
    nessun_overflow
  end
end
