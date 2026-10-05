# frozen_string_literal: true

require "rails_helper"

# CYRA-821 — le tre liste dell'area di controllo (errori, prestazioni, registri) sfogliano e
# riordinano aggiornando SOLTANTO i risultati.
#
# COS'ERA PRIMA: girare pagina rifaceva la pagina intera. Non solo il layout — sidebar, menu,
# intestazione — ma anche tutto ciò che la pagina calcola INTORNO all'elenco e che sfogliare non
# cambia: le chip dei conteggi, il grafico del volume, la sidebar dei campi, l'elenco degli ambienti,
# le viste salvate. Sono aggregati su tabelle a fette mensili da milioni di righe, rifatti a ogni
# clic su «pagina 2» per riscrivere gli stessi numeri.
#
# COSA CAMBIA: i risultati vivono in un turbo-frame e le richieste che arrivano da lì ricevono SOLO
# quel frame — non la pagina intera che il browser poi sfronda. La differenza si vede su due colonne
# diverse e va misurata su entrambe: i byte consegnati (il layout che non viene reso) e le letture
# del database (il lavoro che non viene fatto). È il metro di CYRA-826, e il registro finisce in
# `tmp/performance/aggiornamenti-parziali-monitoraggio.json`.
#
# DOVE PASSA IL CONFINE, ed è la decisione del ticket: nel frame vanno soltanto sfogliare e
# riordinare, che NON cambiano l'insieme filtrato — quindi chip, grafico e facet restano veri mentre
# l'elenco si muove. Cambiare filtro, periodo o ricerca resta una navigazione intera, così tutti i
# numeri che dipendono dai risultati si aggiornano INSIEME: un frame che cambiasse l'insieme
# lasciando le chip di prima mostrerebbe due fotografie diverse della stessa lista.
RSpec.describe "Aggiornamenti parziali dell'area di controllo", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) }
  end

  before do
    # Il documento delle impostazioni globali nasce alla PRIMA lettura, e la nota sulla conservazione
    # dei registri lo legge. In un ambiente vero esiste già da sempre: crearlo qui tiene la colonna
    # delle scritture su ciò che fa la pagina, invece di attribuirle la nascita di una fixture.
    Settings::Global.instance
    accedi(owner)
  end

  after(:context) { PartialUpdate.write!("aggiornamenti-parziali-monitoraggio") }

  def accedi(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Un registro solo per tutte e tre le liste: il confronto ha senso proprio perché le tre pagine
  # dell'area si misurano con lo stesso metro.
  def registro
    PartialUpdate.ledger("aggiornamenti-parziali-monitoraggio",
                         setup: { righe_per_pagina: Pagination::DEFAULT_PER })
  end

  def intestazione_frame(id) = { "Turbo-Frame" => id }

  # Il pieno del confronto: quattordici righe sono due pagine da dodici, il minimo per avere un «pagina 2»
  # da chiedere dentro il frame.
  def volume_pieno = Pagination::DEFAULT_PER + 2

  # Ogni lista dell'area si comporta allo stesso modo, e questo è il contratto. Chi include dichiara
  # `frame`, `barra`, `chip`, `misura_di_volume`, `marcatore_vuoto` e i metodi `indirizzo`, `popola`,
  # `crea`, `selettore`, `senza_risultati`.
  shared_examples "una lista che aggiorna soltanto i risultati" do
    it "la pagina intera porta il frame dei risultati, il contesto e le righe" do
      elenco = popola(3)

      get url

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"))
      expect(response.body).to include(%(data-test="#{barra}"), %(data-test="#{chip}"))
      elenco.each { |record| expect(response.body).to include(selettore(record)) }
    end

    it "chiedere il frame consegna l'elenco senza il resto della pagina" do
      elenco = popola(3)

      get url, headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"))
      elenco.each { |record| expect(response.body).to include(selettore(record)) }
      # Nessun layout: né il contenitore dell'area, né la barra dei filtri, né le chip dei conteggi.
      # È la differenza fra «rispondere col frame» e «rispondere con la pagina intera che contiene
      # il frame», e senza di essa il browser scarica tutto per poi buttarlo via.
      expect(response.body).not_to include('id="main-content"')
      expect(response.body).not_to include(%(data-test="#{barra}"), %(data-test="#{chip}"))
    end

    it "il frame consegna meno byte e fa meno letture della pagina intera" do
      elenco = popola(volume_pieno)
      volume = { misura_di_volume => elenco.size }

      intera = measure_partial_update(registro, operation: "navigazione_pagina", channel: "drive",
                                      volume: volume) do
        get url(page: 2)
      end
      pezzo = allow_n_plus_one do
        measure_partial_update(registro, operation: "navigazione_pagina", channel: "frame",
                               volume: volume) do
          get url(page: 2), headers: intestazione_frame(frame)
        end
      end

      expect(response).to have_http_status(:ok)
      # I byte: il frame non porta il layout, e non è un risparmio marginale.
      expect(pezzo.bytes).to be < (intera.bytes / 2)
      # Le letture: questa è la metà che il solo turbo-frame NON dà. Si ottiene rendendo il solo
      # frammento invece della pagina intera, così le query di ciò che non viene reso non partono.
      expect(pezzo.queries).to be < intera.queries
      # Leggere una lista non scrive: se un domani lo facesse, si vedrebbe nella sua colonna invece
      # di gonfiare quella delle letture.
      expect(intera.writes).to be_zero
      expect(pezzo.writes).to be_zero
    end

    it "sfogliare dentro il frame consegna la pagina chiesta" do
      elenco = popola(volume_pieno)
      prima_pagina = elenco.first(Pagination::DEFAULT_PER)
      seconda_pagina = elenco.drop(Pagination::DEFAULT_PER)

      get url(page: 2), headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      seconda_pagina.each { |record| expect(response.body).to include(selettore(record)) }
      prima_pagina.each { |record| expect(response.body).not_to include(selettore(record)) }
    end

    it "riordinare dentro il frame resta dentro il frame" do
      elenco = popola(3)

      get url(sort: ordinamento), headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"))
      expect(response.body).not_to include('id="main-content"')
      elenco.each { |record| expect(response.body).to include(selettore(record)) }
    end

    it "senza risultati il frame c'è lo stesso, con la spiegazione dentro" do
      popola(3)

      get url(**senza_risultati), headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      # Il nodo da sostituire deve esistere SEMPRE: senza, Turbo non trova il frame nella risposta e
      # al posto dei risultati compare il suo «contenuto mancante», che non è una via d'uscita.
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"))
      expect(response.body).to include(%(data-test="#{marcatore_vuoto}"))
    end

    it "una pagina oltre la fine torna dentro i limiti invece di svuotare il frame" do
      elenco = popola(3)

      get url(page: 99), headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"))
      elenco.each { |record| expect(response.body).to include(selettore(record)) }
    end

    it "un altro frame della pagina riceve la pagina intera, non i soli risultati" do
      popola(3)

      get url, headers: intestazione_frame("un-altro-frame")

      expect(response).to have_http_status(:ok)
      # Chi chiede un frame che qui non c'è deve ricevere la pagina dove quel frame potrebbe esserci:
      # rispondere coi soli risultati gli toglierebbe proprio il nodo che sta cercando.
      expect(response.body).to include('id="main-content"', %(data-test="#{barra}"))
    end

    it "l'indirizzo condiviso apre la pagina intera, frame compreso" do
      elenco = popola(volume_pieno)
      seconda_pagina = elenco.drop(Pagination::DEFAULT_PER)

      get url(page: 2)

      expect(response).to have_http_status(:ok)
      # Scenario 2: l'indirizzo copiato vale da solo. Chi lo apre — o ci torna dal dettaglio — ritrova
      # ambito e contesto completi, e la pagina resta usabile anche se l'aggiornamento parziale non
      # funzionasse: i collegamenti di paginazione e ordinamento sono indirizzi veri, non gesti JS.
      expect(response.body).to include(%(data-test="#{barra}"), %(data-test="#{chip}"))
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"))
      seconda_pagina.each { |record| expect(response.body).to include(selettore(record)) }
    end

    it "il frame non mostra più della pagina intera a chi vede meno progetti" do
      cliente = create(:account)
      dentro = nil
      fuori = nil
      allow_n_plus_one do
        altro_progetto = create(:project, organization: org)
        dentro = crea(project)
        fuori = crea(altro_progetto)
        create(:membership, account: cliente, organization: org, role: :customer)
        create(:project_membership, account: cliente, project: project)
      end
      accedi(cliente)
      volume = { misura_di_volume => 2 }

      intera = measure_partial_update(registro, operation: "permessi_ridotti", channel: "drive",
                                      volume: volume) { get url }
      corpo_intero = response.body
      allow_n_plus_one do
        measure_partial_update(registro, operation: "permessi_ridotti", channel: "frame",
                               volume: volume) do
          get url, headers: intestazione_frame(frame)
        end
      end

      expect(corpo_intero).to include(selettore(dentro))
      expect(corpo_intero).not_to include(selettore(fuori))
      # Il pezzo non è una scorciatoia per vedere di più: stesso perimetro della pagina intera.
      expect(response.body).to include(selettore(dentro))
      expect(response.body).not_to include(selettore(fuori))
      expect(intera.writes).to be_zero
    end

    it "senza sessione il frame dei risultati porta alla login, non a un riquadro muto" do
      popola(3)
      delete logout_path

      get url, headers: intestazione_frame(frame)

      # Un redirect: il riquadro non trova il proprio nome nella risposta e `frame_missing.js`
      # (CYRA-827) apre la login a schermo intero, per ogni riquadro dell'applicazione. Una risposta
      # 200 senza frame lascerebbe l'elenco fermo senza dire perché.
      expect(response).to redirect_to(login_path)
    end

    it "il frame di un'altra organizzazione non consegna niente di suo" do
      estraneo = crea(create(:project))

      get url, headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(selettore(estraneo))
    end
  end

  describe "Errori" do
    let(:frame) { "errors-results" }
    let(:barra) { "errors-toolbar" }
    let(:chip) { "errors-stats" }
    let(:misura_di_volume) { :gruppi }
    let(:marcatore_vuoto) { "errors-no-match" }
    let(:ordinamento) { "-events" }
    let(:senza_risultati) { { q: "niente-che-esista-davvero" } }

    # `ft=1` dichiara «i filtri sono questi, anche se non ce n'è nessuno»: senza, l'elenco parte
    # ristretto ai non risolti e il redirect della memoria dei filtri fotograferebbe se stesso.
    def url(**extra) = member_monitoring_error_groups_path(ft: 1, **extra)

    def crea(progetto, **attributi) = create(:error_group, project: progetto, **attributi)

    # Le date di ultima comparsa sono distanziate di proposito: la lista ordina per quella colonna e
    # con timestamp identici quale riga finisca in quale pagina lo deciderebbe il caso.
    def popola(quanti = volume_pieno)
      allow_n_plus_one do
        Array.new(quanti) { |indice| crea(project, last_seen_at: (indice + 1).minutes.ago) }
      end
    end

    def selettore(record) = %(data-test="error-group-link-#{record.id}")

    it_behaves_like "una lista che aggiorna soltanto i risultati"
  end

  describe "Prestazioni" do
    let(:frame) { "metrics-results" }
    let(:barra) { "metrics-toolbar" }
    let(:chip) { "metrics-stats" }
    let(:misura_di_volume) { :gruppi }
    let(:marcatore_vuoto) { "metrics-no-match" }
    let(:ordinamento) { "-occurrences" }
    let(:senza_risultati) { { q: "niente-che-esista-davvero" } }

    def url(**extra) = member_monitoring_metric_groups_path(ft: 1, **extra)

    def crea(progetto, **attributi) = create(:metric_group, project: progetto, **attributi)

    # L'ordine di partenza è il costo complessivo decrescente: le durate scendono riga per riga così
    # la pagina di ciascuna è decisa dai dati e non dal caso.
    def popola(quanti = volume_pieno)
      allow_n_plus_one do
        Array.new(quanti) { |indice| crea(project, duration_total_ms: (quanti - indice) * 100.0) }
      end
    end

    def selettore(record) = %(data-test="metric-group-link-#{record.id}")

    it_behaves_like "una lista che aggiorna soltanto i risultati"
  end

  describe "Registri" do
    let(:frame) { "logs-results" }
    let(:barra) { "logs-toolbar" }
    let(:chip) { "logs-counts" }
    let(:misura_di_volume) { :registri }
    let(:marcatore_vuoto) { "logs-no-match" }
    let(:ordinamento) { "-level" }
    let(:senza_risultati) { { q: "niente-che-esista-davvero" } }

    def url(**extra) = member_monitoring_log_entries_path(ft: 1, **extra)

    def crea(progetto, **attributi) = create(:log_entry, project: progetto, **attributi)

    def popola(quanti = volume_pieno)
      allow_n_plus_one do
        Array.new(quanti) { |indice| crea(project, occurred_at: (indice + 1).minutes.ago) }
      end
    end

    def selettore(record) = %(data-test="log-entry-link-#{record.id}")

    it_behaves_like "una lista che aggiorna soltanto i risultati"

    # Il raggruppato è l'altra faccia della stessa lista, e si sfoglia anche lui: se restasse fuori
    # dal frame, l'unica vista dei registri che regge ventimila righe tornerebbe a rifare la pagina.
    it "anche la vista raggruppata si sfoglia dentro il frame" do
      # Il raggruppamento mette insieme le righe con la stessa impronta: senza impronta non c'è
      # niente da raggruppare, e la prova guarderebbe il riquadro vuoto invece dell'elenco.
      allow_n_plus_one do
        3.times { |indice| crea(project, fingerprint: "impronta-#{indice}") }
      end

      get url(grouped: "1"), headers: intestazione_frame(frame)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<turbo-frame", %(id="#{frame}"), 'data-test="logs-groups"')
      expect(response.body).not_to include('id="main-content"')
    end
  end

  # Il registro non è un gate di prestazione: è il documento che il ticket chiede di poter rileggere.
  # Qui si prova che esiste, che dichiara su quanti dati è stato preso e che dentro non finiscono
  # contenuti — solo numeri e due etichette da elenco chiuso.
  describe "Il registro delle misure" do
    it "dichiara ambiente, revisione e volumi senza raccogliere contenuti" do
      gruppo = create(:error_group, project: project, title: "RuntimeError: qualcosa di privato")
      volume = { gruppi: 1 }
      measure_partial_update(registro, operation: "riconnessione", channel: "drive", volume: volume) do
        get member_monitoring_error_groups_path(ft: 1)
      end
      allow_n_plus_one do
        measure_partial_update(registro, operation: "riconnessione", channel: "frame", volume: volume) do
          get member_monitoring_error_groups_path(ft: 1), headers: intestazione_frame("errors-results")
        end
      end

      documento = registro.document
      expect(documento["ambiente"]).to eq(App::Version.environment)
      expect(documento["impostazione"]).to include("righe_per_pagina" => Pagination::DEFAULT_PER)
      expect(documento["volumi_osservati"]["gruppi"]).to include("min", "max")
      serializzato = JSON.generate(documento)
      expect(serializzato).not_to include(gruppo.title, owner.email)
    end
  end
end
