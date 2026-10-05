# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Aggiornamenti parziali", type: :system, js: true do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    sign_in_as(owner)
  end

  it "carica la cronologia aprendo il dialog e conserva la pagina" do
    ticket = create(:ticket, organization: org, project: project)
    event = create(:ticket_event, ticket: ticket)
    visit member_ticket_path(ticket)
    expect(page).not_to have_css("[data-test='member-ticket-event-#{event.id}']", visible: :all)
    page.execute_script("window.turboPerformanceMarker = true")
    click_on_test "ticket-history"
    expect(page).to have_css("[data-test='member-ticket-event-#{event.id}']")
    expect(page.evaluate_script("window.turboPerformanceMarker")).to be true
  end

  # CYRA-827 — la scheda progetto: la cronologia arriva quando il riquadro si apre, non prima, e
  # sfogliare i ticket non ricarica la pagina attorno alla lista.
  it "carica la cronologia del progetto solo aprendo il riquadro" do
    create(:activity_event, subject: project, organization: org)
    visit member_project_path(project)
    expect(page).to have_no_css("[data-test='activity-row']", visible: :all)

    page.execute_script("window.turboPerformanceMarker = true")
    click_on_test "project-history"

    expect(page).to have_css("[data-test='activity-row']", minimum: 1)
    # Nessuna navigazione completa: il riquadro ha portato solo se stesso.
    expect(page.evaluate_script("window.turboPerformanceMarker")).to be true
  end

  it "sfoglia i ticket del progetto senza ricostruire la scheda attorno alla lista" do
    stato = create(:ticket_status, organization: org)
    priorita = create(:ticket_priority, organization: org)
    # Diciassette ticket = due pagine da quindici. Le date sono distanziate di proposito: la lista
    # ordina dal più recente, e con timestamp identici quale riga finisca in quale pagina lo
    # deciderebbe il caso. `recente` apre la prima pagina, `vecchio` sta sulla seconda.
    elenco = Array.new(17) do |indice|
      create(:ticket, organization: org, project: project, status: stato, priority: priorita,
             created_at: (17 - indice).hours.ago)
    end
    vecchio = elenco.first
    recente = elenco.last
    visit member_project_path(project)
    expect(page).to have_css("a[href='#{member_ticket_path(recente)}']")

    page.execute_script("window.turboPerformanceMarker = true")
    click_on_test "pagination-next"

    expect(page).to have_css("a[href='#{member_ticket_path(vecchio)}']")
    expect(page).to have_no_css("a[href='#{member_ticket_path(recente)}']")
    # La pagina attorno alla lista è la stessa: solo il riquadro è cambiato.
    expect(page.evaluate_script("window.turboPerformanceMarker")).to be true
    # E l'indirizzo dice dove si è: il collegamento condiviso riapre questa pagina.
    expect(page).to have_current_path(member_project_path(project, page: 2), ignore_query: false)
  end

  # CYRA-827 — la sessione scade mentre il riquadro è ancora da aprire. La risposta è la pagina di
  # login, che il riquadro non contiene: Turbo da solo ne riscriverebbe l'interno con «Content
  # missing», portandosi via ANCHE il collegamento di ripiego che quel riquadro aveva proprio per
  # questo caso. Con il listener su `turbo:frame-missing` si va alla login a schermo intero.
  it "porta alla login, invece di svuotare il riquadro, se la sessione è scaduta" do
    create(:activity_event, subject: project, organization: org)
    visit member_project_path(project)
    expect_test "member-project"

    page.driver.browser.manage.delete_all_cookies
    click_on_test "project-history"

    expect_test "login-submit"
    expect(page).to have_no_text("Content missing")
  end

  # CYRA-827 — il RITORNO dal ticket, che la Definition of Done chiede esplicitamente: aprire un
  # ticket è lasciare la lista (`_top`), e tornare indietro deve riportare alla pagina da cui si era
  # partiti — non alla prima. Regge perché il frame scrive l'indirizzo (`advance`).
  it "torna dal ticket alla stessa pagina della lista da cui si era partiti" do
    stato = create(:ticket_status, organization: org)
    priorita = create(:ticket_priority, organization: org)
    elenco = Array.new(17) do |indice|
      create(:ticket, organization: org, project: project, status: stato, priority: priorita,
             created_at: (17 - indice).hours.ago)
    end
    vecchio = elenco.first
    visit member_project_path(project)
    click_on_test "pagination-next"
    expect(page).to have_css("a[href='#{member_ticket_path(vecchio)}']")

    find("a[href='#{member_ticket_path(vecchio)}']", match: :first).click
    expect_test "member-ticket"

    page.go_back
    expect(page).to have_current_path(member_project_path(project, page: 2), ignore_query: false)
    expect(page).to have_css("a[href='#{member_ticket_path(vecchio)}']")
  end

  it "mostra il training concluso senza una nuova navigazione completa" do
    dataset = create(:dataset, project: project)
    training = create(:dataset_training, dataset: dataset, status: :pending)
    visit member_dataset_training_path(dataset, training)
    expect_test "training-running"
    page.execute_script("window.turboPerformanceMarker = true")
    training.update!(status: :done, system_prompt: "Risultato finale")
    expect(page).to have_css("[data-test='training-prompt']", text: "Risultato finale", wait: 10)
    expect(page.evaluate_script("window.turboPerformanceMarker")).to be true
    expect(page).to have_css('[data-datasets-poll-active-value="false"]')
  end

  # CYRA-826 — la metà che il request spec non può vedere: il browser vero. Qui si misurano le
  # richieste che Turbo fa davvero e i byte che riceve, e si controlla che ciò che l'aggiornamento
  # parziale fa risparmiare non venga pagato altrove — la posizione nel contenuto, il telefono,
  # l'indietro del browser.
  #
  # Il registro finisce in `tmp/performance/aggiornamenti-parziali-browser.json`; quello del giro a
  # richieste sta in spec/requests/member/turbo_performance_spec.rb, e i due si leggono insieme.
  describe "Confronto misurato nel browser" do
    let(:status) { create(:ticket_status, organization: org) }
    let(:priority) { create(:ticket_priority, organization: org) }
    let(:reporter) do
      create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end

    after(:context) { PartialUpdate.write!("aggiornamenti-parziali-browser") }

    # Le costanti del giro: valgono per ogni campione. Il volume dei dati no — quello viaggia sul
    # campione, così il registro non attribuisce a una misura la quantità di un'altra.
    def impostazione_confronto
      { righe_per_pagina: Pagination::DEFAULT_PER,
        finestra_desktop: "1280x520", finestra_telefono: "390x844" }
    end

    # Venti ticket = due pagine PIENE da dieci. Piene di proposito: se la seconda pagina fosse più
    # corta della prima il documento si accorcerebbe e il browser riporterebbe lo scroll dentro i
    # limiti — la posizione risulterebbe persa per la lunghezza della pagina, non per Turbo.
    def volume_pieno = 20

    def registro = PartialUpdate.ledger("aggiornamenti-parziali-browser", setup: impostazione_confronto)

    # Le date di creazione sono distanziate di proposito: la lista ordina per data e con timestamp
    # identici quale ticket finisca in quale pagina lo deciderebbe il caso.
    def popola(quanti = volume_pieno)
      Array.new(quanti) do |indice|
        create(:ticket, organization: org, project: project, status: status, priority: priority,
               reporter: reporter, created_at: (quanti - indice).hours.ago)
      end
    end

    # Il collegamento alla scheda di UN ticket: è il selettore giusto per dire «questa riga c'è».
    # Il codice come TESTO non va bene — «P5-1» sta dentro «P5-12», e un'attesa che passa subito
    # lascia correre la prova mentre Turbo sta ancora navigando (visto dal vivo, CYRA-826).
    def riga_di(ticket) = "a[href='#{member_ticket_path(ticket)}']"

    it "cambiare pagina aggiorna solo il frame e non perde la posizione nel contenuto" do
      elenco = popola
      page.current_window.resize_to(1280, 520)
      visit list_member_tickets_path
      expect(page).to have_css(riga_di(elenco.last))
      page.execute_script("window.turboPerformanceMarker = true")
      scorri_contenuto(180)
      # B25 — past 120px the page header collapses and the browser shifts the scroll so the content
      # stays still: the position to keep is the one after that, not the 180 asked for.
      expect(page).to have_css("header[data-collapsed]")
      prima = posizione_nel_contenuto
      expect(prima).to be > 100

      measure_browser_update(registro, operation: "navigazione_pagina", channel: "frame",
                             volume: { ticket: elenco.size }) do
        # Il click parte da JS di proposito: premuto col mouse, il browser porterebbe prima il
        # pulsante in vista e a spostare la posizione sarebbe il click, non l'aggiornamento.
        page.execute_script("document.querySelector(\"[data-test='pagination-next']\").click()")
        expect(page).to have_css(riga_di(elenco.first))
      end

      # Marker vivo = nessuna ricarica della pagina: è cambiato solo il contenuto del frame.
      expect(page.evaluate_script("window.turboPerformanceMarker")).to be true
      expect(page).to have_no_css(riga_di(elenco.last))
      # E la posizione è rimasta dov'era: l'aggiornamento parziale non riporta in cima.
      expect(posizione_nel_contenuto).to be_within(5).of(prima)
    end

    it "dal telefono l'aggiornamento resta parziale" do
      elenco = popola
      page.current_window.resize_to(390, 844)
      visit list_member_tickets_path
      expect(page).to have_css(riga_di(elenco.last), visible: :all)
      page.execute_script("window.turboPerformanceMarker = true")

      measure_browser_update(registro, operation: "telefono", channel: "frame",
                             volume: { ticket: elenco.size }) do
        click_on_test "pagination-next"
        expect(page).to have_css(riga_di(elenco.first), visible: :all)
      end

      expect(page.evaluate_script("window.turboPerformanceMarker")).to be true
      expect(page).to have_no_css(riga_di(elenco.last), visible: :all)
    end

    # Una sfogliata e ritorno: la sequenza esatta che fa un utente, indirizzo compreso.
    def sfoglia_e_torna(elenco)
      visit list_member_tickets_path
      expect(page).to have_css(riga_di(elenco.last))
      click_on_test "pagination-next"
      expect(page).to have_css(riga_di(elenco.first))
      # La tappa nuova nasce DOPO che il frame si è riempito. Senza aspettare l'indirizzo, il tasto
      # indietro parte prima che quella tappa esista e salta alla pagina di prima ancora: la prova
      # finiva sulla home, non sui risultati (visto dal vivo, CYRA-826).
      expect(page).to have_current_path(/page=2/, url: true)
      page.go_back
      expect(page).to have_current_path(list_member_tickets_path)
    end

    # MISURA DI OGGI, e pesa quanto il conto dei byte: dopo la prima volta, il tasto indietro
    # riporta l'INDIRIZZO della pagina precedente ma non i suoi risultati.
    #
    # PERCHÉ: sfogliare aggiorna il frame e lascia nella storia una tappa il cui indirizzo è quello
    # di prima dello sfogliamento, mentre il documento è quello di dopo. Al ritorno il browser serve
    # quella tappa dalla propria memoria di navigazione — il documento come l'avevi lasciato, cioè
    # già sfogliato — e chi guarda vede risultati che non corrispondono all'indirizzo; basta
    # ricaricare per vederli cambiare. La prima volta la tappa in memoria non c'è, il browser la
    # ricarica e il ritorno è corretto: per questo il primo giro qui prepara e non giudica.
    # Misurato tre volte su tre in esempi diversi, e non è un'attesa breve: dopo tre secondi non
    # cambia.
    #
    # QUANDO QUESTA PROVA DIVENTERÀ ROSSA vorrà dire che indirizzo e risultati sono tornati a
    # corrispondere: si gira l'asserzione e si cita il salto, non si allarga la soglia.
    it "indietro riporta l'indirizzo; dal secondo giro i risultati restano quelli sfogliati" do
      elenco = popola
      volume = { ticket: elenco.size }

      sfoglia_e_torna(elenco)
      page.execute_script("window.turboPerformanceMarker = true")

      measure_browser_update(registro, operation: "indietro", channel: "drive", volume: volume) do
        sfoglia_e_torna(elenco)
      end

      # L'indirizzo è quello della prima pagina...
      expect(page).to have_current_path(list_member_tickets_path)
      # ...e i risultati dipendono dalla memoria di navigazione del browser: dal vivo restano quelli
      # della seconda (tappa servita dalla memoria), in CI headless il browser ricarica e tornano
      # coerenti. Si accetta l'uno o l'altro esito, purché sia netto: mai le due pagine insieme.
      if page.has_css?(riga_di(elenco.first), wait: 2)
        expect(page).to have_no_css(riga_di(elenco.last))
      else
        expect(page).to have_css(riga_di(elenco.last))
        expect(page).to have_no_css(riga_di(elenco.first))
      end

      # Avanti invece è coerente: indirizzo e risultati dicono la stessa cosa.
      page.go_forward
      expect(page).to have_current_path(/page=2/, url: true)
      expect(page).to have_css(riga_di(elenco.first))
    end

    # I due canali sulla STESSA destinazione, altrimenti non è un confronto: chiedere la pagina 2 nel
    # frame contro chiedere la pagina 2 per intero. `Turbo.visit` è la navigazione Drive vera — passa
    # da fetch come il frame, quindi le due misure si leggono con lo stesso metro. Aprire invece la
    # scheda di un ticket avrebbe messo in colonna due operazioni diverse.
    it "sulla stessa destinazione il frame non scarica meno della navigazione intera" do
      elenco = popola
      volume = { ticket: elenco.size }
      visit list_member_tickets_path
      expect(page).to have_css(riga_di(elenco.last))
      wait_for_sidebar_counter

      pezzo = measure_browser_update(registro, operation: "navigazione_pagina", channel: "frame",
                                     volume: volume) do
        click_on_test "pagination-next"
        expect(page).to have_css(riga_di(elenco.first))
      end

      # Ritorno alla prima pagina con un caricamento pulito del browser: `Turbo.visit` qui
      # mostrerebbe prima il documento tenuto in memoria (quello già sfogliato) e la misura
      # successiva partirebbe da uno stato ambiguo. Questo giro non è misurato: serve solo a
      # rimettere le due misure sullo stesso punto di partenza.
      visit list_member_tickets_path
      expect(page).to have_css(riga_di(elenco.last))
      wait_for_sidebar_counter

      intera = measure_browser_update(registro, operation: "navigazione_pagina", channel: "drive",
                                      volume: volume) do
        page.execute_script("Turbo.visit('#{list_member_tickets_path(page: 2)}')")
        expect(page).to have_css(riga_di(elenco.first))
      end

      # Una richiesta per parte: il frame non ne risparmia nemmeno una.
      expect(pezzo.requests).to eq(1)
      expect(intera.requests).to eq(1)
      # E scarica quanto la pagina intera, perché il layout viaggia comunque (vedi il request spec).
      expect(pezzo.bytes).to be > (intera.bytes * 0.9)

      documento = registro.document
      expect(documento["ambiente"]).to eq(App::Version.environment)
      expect(documento["impostazione"]).to include("finestra_telefono" => "390x844")
      expect(documento["volumi_osservati"]["ticket"]).to include("max" => 20)
      expect(documento["numerosità"]).to include("navigazione_pagina/frame")
      # Il registro sono numeri: nessun titolo di ticket, nessun indirizzo di posta.
      serializzato = JSON.generate(documento)
      expect(serializzato).not_to include(owner.email, elenco.first.title)

      expect(registro.write!.exist?).to be true
    end
  end
end
