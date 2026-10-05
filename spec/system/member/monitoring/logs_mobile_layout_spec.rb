# frozen_string_literal: true

require "rails_helper"

# CYRA-814 — I log su schermo stretto. La pagina diventava larga 1326 px dentro uno schermo da 390:
# periodo, Filtri e Viste finivano fuori, e per toccarli bisognava trascinare lateralmente TUTTA la
# pagina invece della sola tabella.
#
# La causa non si vede leggendo le classi: il corpo destro (`min-w-0 flex-1`) sta in un contenitore
# `flex-col ... items-start`, e in colonna `flex-1` governa l'altezza, non la larghezza — la
# larghezza la decide `align-items`, che con `items-start` vale «grande quanto il contenuto». La
# tabella dei log, con le sue colonne a larghezza fissa, chiede più di 1300 px e se li prende. Su
# `lg:` il contenitore diventa una riga e lì `flex-1` torna a essere quello giusto: per questo il
# vincolo di larghezza è solo sotto `lg`.
#
# PERCHÉ NEL BROWSER E NON NEL DOM: la differenza fra «flex-1» e «w-full» è una misura, non una
# classe da leggere. Serve un browser vero, alla larghezza vera.
RSpec.describe "Log su schermo stretto", type: :system, js: true do
  # Il foglio Tailwind è un ARTEFATTO costruito, non un sorgente: se manca, il browser rende la
  # pagina senza una sola classe applicata e ogni misura di larghezza diventa finta — la prova
  # passerebbe a vuoto, verde su una pagina che nella realtà è rotta. Nessun altro system spec se
  # ne accorgerebbe: gli altri leggono le CLASSI, questo misura i PIXEL.
  # Si costruisce una volta per file. Se la costruzione non riesce ma il foglio c'è già (in CI può
  # arrivare da un passo di precompilazione), si prosegue con quello: a dire se è arrivato davvero
  # al browser è l'asserzione su `overflow-x: auto` più sotto.
  FOGLIO_TAILWIND = Rails.root.join("app/assets/builds/tailwind.css")

  before(:context) do
    costruito = system("bin/rails tailwindcss:build", out: File::NULL, err: File::NULL)
    raise "tailwindcss:build fallito e #{FOGLIO_TAILWIND} non esiste" unless costruito || FOGLIO_TAILWIND.exist?
  end

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STOR") }

  before { Types::InstallDefaults.call(organization: org) }

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  # Log abbastanza lunghi da riempire la colonna del messaggio: è la tabella larga a trascinare
  # fuori il resto, quindi una riga corta non riprodurrebbe niente.
  def crea_log(quanti: 30, data: {})
    quanti.times do |i|
      create(:log_entry, project:, data: data,
                         message: "payment webhook #{i} received from the upstream provider and rejected " \
                                  "because the signature did not match the shared secret",
                         logger_name: "payments.webhooks.inbound")
    end
  end

  # 390×844 è la misura del telefono su cui il guasto è stato misurato. `resize_to` NON basta:
  # ridimensiona la finestra, e Chrome ha una larghezza minima di finestra che lascia la pagina
  # a ~470 px — larghezza alla quale la barra dei filtri va a capo da sé e il guasto scompare.
  # L'emulazione del dispositivo è l'unico modo di avere davvero 390 px di pagina.
  def emula_telefono(larghezza: 390)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: larghezza, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  # L'emulazione è del BROWSER, che resta acceso per tutto il processo: non toglierla lascerebbe
  # ogni esempio successivo su uno schermo da telefono (stessa trappola del resize documentata in
  # spec/support/js_system.rb).
  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.respond_to?(:browser)
  end

  def larghezza_pagina
    page.evaluate_script("[document.querySelector('main').scrollWidth, document.querySelector('main').clientWidth]")
  end

  # Il bordo destro di un elemento, in pixel dal bordo sinistro della finestra.
  def bordo_destro(test_id)
    page.evaluate_script("document.querySelector(\"[data-test='#{test_id}']\").getBoundingClientRect().right")
  end

  describe "a 390 px, con log da leggere" do
    before do
      crea_log
      sign_in_as(owner_account)
      emula_telefono
      visit member_monitoring_log_entries_path
      expect(page).to have_css("[data-test='log-entries-table']")
    end

    it "la pagina non è più larga dello schermo" do
      scroll_width, client_width = larghezza_pagina

      expect(client_width).to eq(390)
      expect(scroll_width).to eq(client_width)
    end

    it "periodo, Filtri e Viste restano dentro lo schermo" do
      expect(bordo_destro("logs-toolbar-view-menu")).to be <= 390
      expect(bordo_destro("logs-toolbar-filters-menu")).to be <= 390
      expect(bordo_destro("saved-views")).to be <= 390
    end

    it "la tabella conserva il proprio scorrimento laterale" do
      measurements = page.evaluate_script(<<~'JS')
        (() => {
          const s = document.querySelector("[data-test='log-entries-table'] .overflow-x-auto");
          return [getComputedStyle(s).overflowX, s.scrollWidth, s.clientWidth];
        })()
      JS

      # `overflow-x: auto` computato prova anche che il foglio di stile è arrivato al browser:
      # senza, tutte le misure di questo file sarebbero prive di significato.
      expect(measurements[0]).to eq("auto")
      expect(measurements[1]).to be > measurements[2]
    end

    it "il grafico del volume conserva il proprio scorrimento laterale" do
      measurements = page.evaluate_script(<<~'JS')
        (() => {
          const s = document.querySelector("[data-test='logs-volume-chart'] .overflow-x-auto");
          return [getComputedStyle(s).overflowX, s.scrollWidth, s.clientWidth];
        })()
      JS

      expect(measurements[0]).to eq("auto")
      expect(measurements[1]).to be > measurements[2]
      expect(page.evaluate_script("document.querySelector(\"[data-test='logs-volume-chart']\").getBoundingClientRect().right")).to be <= 390
    end
  end

  # CYRA-814 (DoD) — senza risultati la pagina cambia forma: niente tabella, niente grafico, solo il
  # blocco «nessuna corrispondenza». I filtri restano, e devono restare raggiungibili anche lì.
  it "a 390 px resta nello schermo anche quando il filtro non trova niente" do
    crea_log(quanti: 3)
    sign_in_as(owner_account)
    emula_telefono
    visit member_monitoring_log_entries_path(q: "nessun-messaggio-contiene-questo")

    expect(page).to have_css("[data-test='logs-no-match']")
    scroll_width, client_width = larghezza_pagina
    expect(scroll_width).to eq(client_width)
    expect(bordo_destro("logs-toolbar-view-menu")).to be <= 390
    expect(bordo_destro("logs-toolbar-filters-menu")).to be <= 390
  end

  # Il vincolo di larghezza vale SOTTO lg: su schermo largo il contenitore torna una riga e la
  # sidebar dei campi deve restare affiancata all'elenco, non impilata sopra.
  it "su schermo largo la sidebar dei campi resta accanto all'elenco" do
    crea_log(quanti: 3, data: { "amount_cents" => 4200 })
    sign_in_as(owner_account)
    visit member_monitoring_log_entries_path

    expect(page).to have_css("[data-test='logs-facets']")
    affiancate = page.evaluate_script(<<~'JS')
      (() => {
        const a = document.querySelector("[data-test='logs-facets']").getBoundingClientRect();
        const b = document.querySelector("[data-test='log-entries-table']").getBoundingClientRect();
        return a.right <= b.left && a.top < b.bottom;
      })()
    JS

    expect(affiancate).to be(true)
  end
end
