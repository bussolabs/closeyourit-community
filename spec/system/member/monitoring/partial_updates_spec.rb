# frozen_string_literal: true

require "rails_helper"

# CYRA-821 — la metà che il request spec non può vedere: il browser vero.
#
# Il request spec (spec/requests/member/monitoring/partial_updates_spec.rb) prova che chiedendo il
# frame si riceve il solo frammento, e misura quanto costa. Qui si prova che l'aggiornamento è DAVVERO
# parziale — la pagina non viene rifatta — e che quello che il ticket chiede di non rompere non si
# rompe: l'indirizzo che segue i risultati, i numeri in cima che restano coerenti, i collegamenti che
# escono dal frame, la tastiera, il telefono e il ritorno dalla scheda.
#
# IL SEGNALE, e non è quello che verrebbe in mente per primo: un valore appeso a `window` NON serve.
# Turbo Drive non ricarica la pagina, sostituisce il `body`: `window` sopravvive anche a una
# navigazione intera, e il marcatore direbbe «parziale» sempre. Qui si segna invece un NODO che sta
# FUORI dal frame — la barra dei filtri. Un aggiornamento di frame non la tocca e il segno resta;
# una navigazione intera rifà il `body` e il segno sparisce con lei. È la distinzione da misurare.
#
# Il registro di questo giro finisce in `tmp/performance/aggiornamenti-parziali-monitoraggio-browser.json`
# e si legge insieme a quello a richieste: lì ci sono le letture del database, qui le richieste che il
# browser fa davvero e i byte che riceve.
#
# LA CRONOLOGIA. I frame usano `data-turbo-action="advance"` come ogni altro elenco a frame del
# prodotto: l'indirizzo segue i risultati e il tasto indietro ripercorre le pagine sfogliate. Ciò che
# CYRA-826 ha misurato sulla lista dei ticket vale anche qui: al ritorno il browser può servire la
# tappa dalla propria memoria di navigazione (il documento già sfogliato) oppure ricaricarla. Si
# accetta l'uno o l'altro esito, purché sia netto: mai le due pagine insieme. L'esempio in fondo è la
# rete su quel confine, con lo stesso metro di spec/system/member/turbo_performance_spec.rb.
RSpec.describe "Aggiornamenti parziali dell'area di controllo", type: :system, js: true do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) }
  end

  after(:context) { PartialUpdate.write!("aggiornamenti-parziali-monitoraggio-browser") }

  def registro
    PartialUpdate.ledger("aggiornamenti-parziali-monitoraggio-browser",
                         setup: { righe_per_pagina: Pagination::DEFAULT_PER,
                                  finestra_desktop: "1280x800", finestra_telefono: "390x844" })
  end

  # Quattordici gruppi sono due pagine da dodici. Le date di ultima comparsa sono distanziate di proposito:
  # la lista ordina per quella colonna e con timestamp identici quale riga finisca in quale pagina lo
  # deciderebbe il caso.
  def popola(quanti = Pagination::DEFAULT_PER + 2)
    Array.new(quanti) do |indice|
      create(:error_group, project: project, title: "Errore numero #{indice}",
             last_seen_at: (indice + 1).minutes.ago)
    end
  end

  # `ft=1` dichiara «i filtri sono questi, anche se non ce n'è nessuno»: senza, l'elenco parte
  # ristretto ai non risolti e la prova guarderebbe una lista diversa da quella che ha popolato.
  def elenco_path(**extra) = member_monitoring_error_groups_path(ft: 1, **extra)

  def riga_di(gruppo) = "[data-test='error-group-link-#{gruppo.id}']"

  # Il segno va su un nodo fuori dal frame: la barra dei filtri, che sfogliare non deve toccare.
  def segna_il_contesto
    page.execute_script("document.querySelector(\"[data-test='errors-toolbar']\").dataset.cyra821 = 'segnato'")
  end

  def contesto_conservato?
    page.evaluate_script(<<~JS) == "segnato"
      (() => {
        const barra = document.querySelector("[data-test='errors-toolbar']");
        return barra ? barra.dataset.cyra821 : null;
      })()
    JS
  end

  # I quattro numeri in cima, letti dal vivo: sono il contesto che sfogliare NON deve muovere.
  def numeri_in_cima
    %w[stat-unresolved stat-resolved stat-ignored stat-issues].map do |chip|
      find("[data-test='#{chip}']").text
    end
  end

  it "sfogliare aggiorna solo i risultati e lascia coerenti numeri, barra e indirizzo" do
    elenco = popola
    sign_in_as(owner)
    visit elenco_path
    expect(page).to have_css(riga_di(elenco.first))
    prima = numeri_in_cima
    segna_il_contesto

    measure_browser_update(registro, operation: "navigazione_pagina", channel: "frame",
                           volume: { gruppi: elenco.size }) do
      click_on_test "pagination-next"
      expect(page).to have_css(riga_di(elenco.last))
    end

    # La barra è ancora IL NODO di prima: la pagina non è stata rifatta, è cambiato il solo frame.
    expect(contesto_conservato?).to be true
    expect(page).to have_no_css(riga_di(elenco.first))
    # L'indirizzo segue i risultati: la pagina che si sta guardando si copia e si riapre.
    expect(page).to have_current_path(/page=2/, url: true)
    # E i numeri in cima non si sono mossi, perché sfogliare non cambia l'insieme filtrato: se
    # cambiassero senza che l'insieme cambi, sarebbero due fotografie diverse della stessa lista.
    expect(numeri_in_cima).to eq(prima)
    expect(page).to have_css("[data-test='errors-toolbar']")
  end

  # I due canali sulla STESSA destinazione, altrimenti non è un confronto: chiedere la pagina 2 nel
  # frame contro chiedere la pagina 2 per intero. `Turbo.visit` è la navigazione Drive vera — passa
  # da `fetch` come il frame, quindi le due misure si leggono con lo stesso metro.
  it "downloads a fraction of the full navigation body for the same destination" do
    elenco = popola
    volume = { gruppi: elenco.size }
    sign_in_as(owner)
    visit elenco_path
    expect(page).to have_css(riga_di(elenco.first))
    wait_for_sidebar_counter

    pezzo = measure_browser_update(registro, operation: "navigazione_pagina", channel: "frame",
                                   volume: volume) do
      click_on_test "pagination-next"
      expect(page).to have_css(riga_di(elenco.last))
    end

    # Ritorno alla prima pagina con un caricamento pulito del browser: `Turbo.visit` qui mostrerebbe
    # prima il documento tenuto in memoria (quello già sfogliato) e la misura successiva partirebbe
    # da uno stato ambiguo. Questo giro non è misurato: rimette le due misure sullo stesso punto.
    visit elenco_path
    expect(page).to have_css(riga_di(elenco.first))
    wait_for_sidebar_counter

    intera = measure_browser_update(registro, operation: "navigazione_pagina", channel: "drive",
                                    volume: volume) do
      page.execute_script("Turbo.visit('#{elenco_path(page: 2)}')")
      expect(page).to have_css(riga_di(elenco.last))
    end

    # Una richiesta per parte: il risparmio non è nel NUMERO di viaggi, è in quanto pesa il viaggio.
    # The sidebar loads its approval count independently of the measured navigation.
    expect(pezzo.requests).to eq(1)
    expect(intera.requests).to eq(1)
    expect(pezzo.bytes).to be < (intera.bytes / 2)
  end

  it "dal telefono l'aggiornamento resta parziale" do
    elenco = popola
    sign_in_as(owner)
    page.current_window.resize_to(390, 844)
    visit elenco_path
    expect(page).to have_css(riga_di(elenco.first), visible: :all)
    segna_il_contesto

    measure_browser_update(registro, operation: "telefono", channel: "frame",
                           volume: { gruppi: elenco.size }) do
      click_on_test "pagination-next"
      expect(page).to have_css(riga_di(elenco.last), visible: :all)
    end

    expect(contesto_conservato?).to be true
    expect(page).to have_no_css(riga_di(elenco.first), visible: :all)
  end

  it "con la tastiera sfogliare funziona come col mouse" do
    elenco = popola
    sign_in_as(owner)
    visit elenco_path
    expect(page).to have_css(riga_di(elenco.first))
    segna_il_contesto

    # Il collegamento è un link vero: si raggiunge col tasto di tabulazione e si preme con Invio.
    # Non è un gesto inventato in JavaScript, ed è la ragione per cui la pagina resta usabile.
    find("[data-test='pagination-next']").send_keys(:enter)

    expect(page).to have_css(riga_di(elenco.last))
    expect(contesto_conservato?).to be true
    expect(page).to have_current_path(/page=2/, url: true)
  end

  it "aprire una riga esce dal frame, e tornare indietro riporta i risultati sfogliati" do
    elenco = popola
    sign_in_as(owner)
    visit elenco_path
    click_on_test "pagination-next"
    expect(page).to have_css(riga_di(elenco.last))
    expect(page).to have_current_path(/page=2/, url: true)
    segna_il_contesto

    find(riga_di(elenco.last)).click

    # La scheda si apre al posto della pagina, non dentro l'elenco: è una navigazione intera.
    expect(page).to have_current_path(member_monitoring_error_group_path(elenco.last),
                                      ignore_query: true)
    expect(contesto_conservato?).to be false

    # Scenario 2 — tornando indietro dalla scheda si ritrova la pagina che si stava guardando:
    # indirizzo e risultati dicono la stessa cosa.
    page.go_back
    expect(page).to have_current_path(/page=2/, url: true)
    expect(page).to have_css(riga_di(elenco.last))
    expect(page).to have_no_css(riga_di(elenco.first))
  end

  it "cambiare filtro rifà la pagina intera, così i numeri si muovono insieme all'elenco" do
    elenco = popola(3)
    risolto = create(:error_group, :resolved, project: project, title: "Errore già chiuso")
    sign_in_as(owner)
    visit elenco_path
    expect(page).to have_css(riga_di(risolto))
    segna_il_contesto

    # Le chip in cima sono filtri: stanno FUORI dal frame, quindi premerle rifà la pagina intera.
    # È la decisione del ticket — un frame che cambiasse l'insieme lascerebbe indietro proprio i
    # numeri che quel cambio deve muovere.
    click_on_test "stat-unresolved"

    expect(page).to have_no_css(riga_di(risolto))
    elenco.each { |gruppo| expect(page).to have_css(riga_di(gruppo)) }
    expect(contesto_conservato?).to be false
    expect(find("[data-test='stat-unresolved']")).to have_text(elenco.size.to_s)
  end

  # LA RETE SULLA CRONOLOGIA. Si ripete due volte la sequenza sfoglia-e-torna, perché la prima volta
  # la tappa non è ancora in memoria del browser e il ritorno è sempre una ricarica: è dal secondo
  # giro che la tappa può arrivare dalla memoria di navigazione (CYRA-826).
  it "il tasto indietro riporta l'indirizzo della prima pagina e una sola pagina di risultati" do
    elenco = popola
    sign_in_as(owner)

    2.times do
      visit elenco_path
      expect(page).to have_css(riga_di(elenco.first))
      click_on_test "pagination-next"
      expect(page).to have_css(riga_di(elenco.last))
      # `advance`: l'indirizzo segue i risultati, si copia e si riapre.
      expect(page).to have_current_path(/page=2/, url: true)

      page.go_back

      # L'indirizzo è quello della prima pagina...
      expect(page).to have_current_path(elenco_path)
      # ...e i risultati dipendono dalla memoria di navigazione del browser: o la prima pagina
      # (ricaricata) o la seconda (servita dalla memoria). Mai le due insieme.
      if page.has_css?(riga_di(elenco.first), wait: 2)
        expect(page).to have_no_css(riga_di(elenco.last))
      else
        expect(page).to have_css(riga_di(elenco.last))
        expect(page).to have_no_css(riga_di(elenco.first))
      end
    end
  end

  it "la barra dei filtri non punta al frame dei risultati" do
    popola(3)
    sign_in_as(owner)
    visit elenco_path

    # Il confine, scritto nel DOM: la barra invia una navigazione intera. Se un giorno qualcuno le
    # facesse puntare il frame, i filtri cambierebbero l'elenco lasciando i numeri di prima.
    expect(page).to have_css("[data-test='errors-toolbar'] form")
    expect(page).to have_no_css("[data-test='errors-toolbar'] form[data-turbo-frame]")
  end
end
