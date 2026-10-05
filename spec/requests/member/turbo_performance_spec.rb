# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Caricamento selettivo delle pagine", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: account, organization: org, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
    # The topbar reads the AI switches, and the settings row is created on first read: once per
    # installation, not per page, so it must not count as a write of the measured page. CYRA-908
    Settings::Global.instance
  end

  def queries_during
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    queries
  end

  it "il dettaglio non materializza commenti e cronologia completa" do
    id = ticket.id
    queries = queries_during { get member_ticket_path(id) }
    expect(response).to have_http_status(:ok)
    # CYRA-883 — only the last two comments, for the preview at the bottom of the detail.
    expect(queries.grep(/SELECT "ticketing_comments"\.\*/)).to all(match(/LIMIT/))
    event_reads = queries.grep(/SELECT "ticketing_events"\.\*/)
    expect(event_reads).to all(match(/LIMIT/))
    expect(response.body).to include('loading="lazy"', 'section=history')
  end

  it "la cronologia richiesta nel frame resta accessibile" do
    get member_ticket_path(ticket, section: "history"), headers: { "Turbo-Frame" => "ticket-history" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<turbo-frame id="ticket-history"')
    expect(response.body).not_to include('data-test="ticket-tabs"')
  end

  it "la cronologia sfoglia gli eventi senza perdere il filtro della sezione" do
    first = create(:ticket_event, ticket: ticket, created_at: 2.hours.ago)
    last = create(:ticket_event, ticket: ticket, created_at: 1.hour.ago)
    get member_ticket_path(ticket, section: "history", per: 1), headers: { "Turbo-Frame" => "ticket-history" }
    expect(response.body).to include("member-ticket-event-#{last.id}")
    expect(response.body).not_to include("member-ticket-event-#{first.id}")
    get member_ticket_path(ticket, section: "history", per: 1, page: 2), headers: { "Turbo-Frame" => "ticket-history" }
    expect(response.body).to include("member-ticket-event-#{first.id}")
  end

  it "le schede secondarie non leggono i corpi dei resoconti" do
    create(:ticket_report, ticket: ticket, organization: org, author: account,
           body: "Resoconto lungo da leggere nella sua scheda")
    sql = queries_during { get member_ticket_path(ticket, tab: "analysis") }
    expect(response).to have_http_status(:ok)
    expect(sql.grep(/SELECT "ticketing_reports"\.\*/)).to be_empty
    expect(sql.grep(/SELECT "ticketing_reports"\."body"/)).to be_empty
    expect(response.body).to include('data-test="ticket-tab-report"')
  end

  it "la cronologia di un altro tenant non è accessibile" do
    other = create(:ticket, organization: create(:organization))
    get member_ticket_path(other, section: "history"), headers: { "Turbo-Frame" => "ticket-history" }
    expect(response).to have_http_status(:not_found)
  end

  it "il trascinamento JSON conferma senza redirect o pagina HTML" do
    next_status = create(:ticket_status, organization: org)
    patch status_member_ticket_path(ticket), params: { status_id: next_status.id },
          headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:no_content)
    expect(response.headers["Location"]).to be_nil
    expect(ticket.reload.status_id).to eq(next_status.id)
  end

  it "il training offre un frame aggiornabile senza la navigazione del layout" do
    dataset = create(:dataset, project: project)
    training = create(:dataset_training, dataset: dataset, status: :pending)
    get member_dataset_training_path(dataset, training), headers: { "Turbo-Frame" => "dataset-progress" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<turbo-frame id="dataset-progress"', 'data-datasets-poll-active-value="true"')
    expect(response.body).not_to include('data-controller="ui--mobile-nav keyboard"')
  end

  it "il training completato ferma gli aggiornamenti e mostra il risultato" do
    dataset = create(:dataset, project: project)
    training = create(:dataset_training, dataset: dataset, status: :done, system_prompt: "Risultato finale")
    get member_dataset_training_path(dataset, training), headers: { "Turbo-Frame" => "dataset-progress" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-datasets-poll-active-value="false"', "Risultato finale")
  end

  # CYRA-826 — il confronto MISURATO. Gli esempi qui sopra provano che una parte di pagina si carica
  # per conto suo; questo blocco dice quanto costa rispetto alla pagina intera, con gli stessi dati e
  # lo stesso indirizzo, tenendo distinte le quattro misure che il ticket vuole separate: richieste,
  # byte consegnati, letture del database e tempo.
  #
  # COSA SI SCOPRE, ed è il punto: il frame consegna una frazione dei byte — il layout non viene
  # reso — ma NON risparmia le letture, perché la action gira comunque per intero. «Sembra più
  # fluida» e «lavora di meno» sono due colonne diverse, e restano due colonne diverse.
  #
  # DOVE SI RILEGGE: `tmp/performance/aggiornamenti-parziali-richieste.json`, con ambiente,
  # revisione, volume dei dati e numerosità dei campioni. Il giro nel browser — desktop, telefono,
  # posizione nel contenuto, indietro/avanti — sta in spec/system/member/turbo_performance_spec.rb.
  #
  # NESSUNA SOGLIA SUL TEMPO: in CI il tempo di parete dipende dalla macchina e dagli altri shard.
  # Si asserisce solo ciò che è deterministico a parità di dati (byte e letture); i millisecondi
  # restano nel registro, da leggere.
  describe "Confronto misurato del lavoro evitato" do
    let(:status) { create(:ticket_status, organization: org) }
    let(:priority) { create(:ticket_priority, organization: org) }
    # Reporter condiviso dai ticket di massa: lasciato al factory sarebbero un account e una
    # membership in più per riga, pagati da ogni esempio che popola la lista.
    let(:reporter) do
      create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end

    after(:context) { PartialUpdate.write!("aggiornamenti-parziali-richieste") }

    # Le costanti del confronto: quello che vale per ogni campione. Il VOLUME dei dati non sta qui —
    # ogni esempio misura sul numero di righe che gli serve e lo dichiara sul proprio campione, così
    # il registro non attribuisce a una misura presa su tre ticket la quantità di un'altra.
    def impostazione_confronto
      { righe_per_pagina: Pagination::DEFAULT_PER,
        card_per_colonna: Ticketing::Constants::BOARD_COLUMN_PAGE }
    end

    # Il pieno del confronto: ventiquattro ticket sono tre pagine di tabella e due blocchi di
    # colonna nella bacheca — abbastanza da vedere sia la paginazione sia il caricamento a blocchi.
    def volume_pieno = 24

    def registro = PartialUpdate.ledger("aggiornamenti-parziali-richieste", setup: impostazione_confronto)

    # I ticket di massa del confronto. Il setto di Prosopite si sospende sul SETUP e solo lì: creare
    # N ticket ripete per forza la lettura del progetto (numerazione) e quella della membership
    # (isolamento tenant) — sono query di fixture, non del codice che serve la pagina.
    def popola(quanti = volume_pieno)
      allow_n_plus_one do
        create_list(:ticket, quanti, organization: org, project: project, status: status,
                    priority: priority, reporter: reporter)
      end
    end

    def frame_header(nome) = { "Turbo-Frame" => nome }

    # Lo stesso contenuto chiesto due volte, una per canale. Per Prosopite il secondo giro ripete
    # ogni query del primo: è la misura, non un N+1 del prodotto — quello resta coperto dagli esempi
    # a richiesta singola — quindi la guardia si sospende sul solo bis.
    def comparable_version(operazione, volume:, intera:, pezzo:)
      misura_intera = measure_partial_update(registro, operation: operazione, channel: "drive",
                                             volume: volume, &intera)
      corpo_intero = response.body
      misura_pezzo = allow_n_plus_one do
        measure_partial_update(registro, operation: operazione, channel: "frame", volume: volume, &pezzo)
      end
      { intera: misura_intera, pezzo: misura_pezzo, corpo_intero: corpo_intero, corpo_pezzo: response.body }
    end

    # Il volume si passa a mano e non si conta al volo: una COUNT dentro l'esempio sarebbe una query
    # ripetuta a ogni misura, cioè rumore per la guardia N+1 proprio nel file che misura le query.
    def misura_frame(operazione, volume:, params: {})
      measure_partial_update(registro, operation: operazione, channel: "frame", volume: volume) do
        get list_member_tickets_path, params: params, headers: frame_header("tickets-results")
      end
    end

    it "il filtro nel frame consegna le stesse righe senza risparmiare letture" do
      elenco = popola(3)
      url = list_member_tickets_path(status_id: [ status.id ])
      esito = comparable_version("filtro", volume: { ticket: elenco.size },
                        intera: -> { get url },
                        pezzo: -> { get url, headers: frame_header("tickets-results") })

      expect(response).to have_http_status(:ok)
      # Le righe sono le stesse: chiedere il pezzo non è chiedere di meno all'utente.
      elenco.each { |ticket| expect(esito[:corpo_pezzo]).to include(ticket.code) }
      expect(esito[:pezzo].bytes).to be <= esito[:intera].bytes
      # E il database lavora uguale: la action gira per intero anche quando si chiede solo il pezzo.
      # È la metà della storia che la sensazione di fluidità non racconta.
      expect(esito[:pezzo].queries).to be_positive
      expect(esito[:pezzo].queries).to be <= esito[:intera].queries
      # Letture e scritture restano due colonne. Oggi sfogliare la lista non scrive niente — la
      # memoria dei filtri sta nella sessione — e il registro lo dice invece di sommare le due cose:
      # il giorno in cui una pagina cominciasse a scrivere, si vedrebbe qui e non dentro «letture».
      expect(esito[:intera].writes).to be_zero
      expect(esito[:pezzo].writes).to be_zero
    end

    # MISURA DI OGGI, ed è il numero che il ticket cercava: sulla lista il frame NON risparmia niente.
    #
    # `Member::BaseController` dichiara `layout "member"` come nome fisso, e quel nome vince sul
    # layout condizionale che turbo-rails installa su ActionController (`turbo_rails/frame` quando la
    # richiesta porta l'header `Turbo-Frame`). Risultato: la risposta al frame si porta dietro
    # l'intestazione completa — importmap, un centinaio di modulepreload, la sidebar — e il browser
    # butta via tutto tranne il frame. La cronologia del ticket invece rinuncia al layout a mano
    # (`render :history, layout: turbo_frame_request? ? false : "member"`) e lì il risparmio è vero.
    #
    # QUANDO QUESTA PROVA DIVENTERÀ ROSSA vorrà dire che qualcuno ha tolto il layout anche ai frame:
    # è l'intervento che questo confronto serve a giustificare. Allora si aggiorna il verso della
    # misura e si cita il salto — non si allarga la soglia.
    it "il frame della lista rispedisce il layout, quello della cronologia no" do
      elenco = popola(3)
      lista = comparable_version("filtro", volume: { ticket: elenco.size },
                        intera: -> { get list_member_tickets_path },
                        pezzo: lambda {
                          get list_member_tickets_path, headers: frame_header("tickets-results")
                        })
      allow_n_plus_one { create_list(:ticket_event, 3, ticket: ticket) }
      cronologia = allow_n_plus_one do
        comparable_version("cambio_scheda", volume: { eventi: 3 },
                  intera: -> { get member_ticket_path(ticket) },
                  pezzo: lambda {
                    get member_ticket_path(ticket, section: "history"),
                        headers: frame_header("ticket-history")
                  })
      end

      expect(lista[:corpo_pezzo]).to include('id="main-content"')
      expect(lista[:pezzo].bytes).to be > (lista[:intera].bytes * 0.9)
      expect(cronologia[:corpo_pezzo]).not_to include('id="main-content"')
      expect(cronologia[:pezzo].bytes).to be < (cronologia[:intera].bytes * 0.5)
    end

    it "i filtri combinati non moltiplicano le letture del frame" do
      elenco = popola(3)
      volume = { ticket: elenco.size }
      singolo = misura_frame("filtro", volume: volume, params: { status_id: [ status.id ] })
      combinato = allow_n_plus_one do
        misura_frame("filtri_combinati", volume: volume,
                     params: { status_id: [ status.id ], priority_id: [ priority.id ],
                               kind: [ "bug" ], project_id: [ project.id ] })
      end

      expect(response).to have_http_status(:ok)
      # Un filtro in più è una condizione in più sulla stessa query, non una query in più.
      expect(combinato.queries).to be <= singolo.queries
      expect(combinato.bytes).to be_positive
    end

    it "il cambio scheda porta la cronologia senza il resto della pagina" do
      eventi = 6
      allow_n_plus_one { create_list(:ticket_event, eventi, ticket: ticket) }
      esito = comparable_version("cambio_scheda", volume: { ticket: 1, eventi: eventi },
                        intera: -> { get member_ticket_path(ticket) },
                        pezzo: lambda {
                          get member_ticket_path(ticket, section: "history"),
                              headers: frame_header("ticket-history")
                        })

      expect(response).to have_http_status(:ok)
      expect(esito[:corpo_pezzo]).to include('<turbo-frame id="ticket-history"')
      expect(esito[:corpo_pezzo]).not_to include('data-test="ticket-tabs"', 'id="main-content"')
      expect(esito[:pezzo].bytes).to be < esito[:intera].bytes
    end

    it "l'aggiornamento in arrivo consegna solo il blocco successivo, non la bacheca" do
      elenco = popola
      volume = { ticket: elenco.size }
      bacheca = measure_partial_update(registro, operation: "aggiornamento_in_arrivo", channel: "drive",
                                       volume: volume) do
        get member_tickets_path
      end
      blocco = allow_n_plus_one do
        measure_partial_update(registro, operation: "aggiornamento_in_arrivo", channel: "stream",
                               volume: volume) do
          get column_member_tickets_path(status_id: status.id, page: 2),
              headers: { "Accept" => "text/vnd.turbo-stream.html" }
        end
      end

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      # Qui il risparmio è vero su entrambi i fronti: una colonna sola, e solo le card che mancano.
      expect(blocco.bytes).to be < bacheca.bytes
      expect(blocco.queries).to be < bacheca.queries
    end

    it "le letture del frame non crescono con le righe mostrate (0, 1 e N)" do
      vuoto = misura_frame("volume_zero", volume: { ticket: 0 })
      popola(1)
      uno = allow_n_plus_one { misura_frame("volume_uno", volume: { ticket: 1 }) }
      popola(11)
      molti = allow_n_plus_one { misura_frame("volume_molti", volume: { ticket: 12 }) }

      expect(vuoto.queries).to be <= uno.queries
      # La prova che nessuna riga si porta dietro la sua query: dodici righe costano quanto una.
      expect(molti.queries).to be <= uno.queries
      expect(molti.bytes).to be > uno.bytes
    end

    it "filtro vuoto, valore inesistente e pagina oltre la fine restano dentro il frame" do
      elenco = popola(3)
      volume = { ticket: elenco.size }
      senza_ticket = create(:ticket_status, organization: org)

      # Nessun risultato: il frame c'è e dice che non c'è niente. Nessun redirect, nessuna pagina
      # d'errore, e il browser trova comunque il nodo da sostituire.
      vuoto = misura_frame("errore_filtro", volume: volume, params: { status_id: [ senza_ticket.id ] })
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="tickets-results"', 'data-test="tickets-no-results"')

      # Un identificativo che non esiste non rompe la pagina e non allarga il perimetro: risponde
      # come un filtro senza risultati.
      ignoto = allow_n_plus_one do
        misura_frame("errore_filtro", volume: volume, params: { status_id: [ SecureRandom.uuid ] })
      end
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="tickets-results"', 'data-test="tickets-no-results"')
      elenco.each { |ticket| expect(response.body).not_to include(ticket.code) }

      # E una pagina oltre la fine: nessun giro di ripiego, nessuna riga inventata. Il marker dei
      # filtri ricordati viaggia esplicito: senza, la lista rimanda all'ultimo filtro salvato (302)
      # e la misura fotograferebbe un redirect invece del frame.
      piena = allow_n_plus_one { misura_frame("filtro", volume: volume, params: { ft: 1 }) }
      oltre_la_fine = allow_n_plus_one do
        misura_frame("errore_filtro", volume: volume, params: { ft: 1, page: 99 })
      end
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="tickets-results"')
      elenco.each { |ticket| expect(response.body).to include(ticket.code) }
      # La pagina 99 di una lista che ne ha una sola viene riportata dentro i limiti: stesso
      # frammento, stesso costo. Nessuna riga inventata e nessun secondo giro.
      expect(oltre_la_fine.bytes).to be_within(piena.bytes * 0.01).of(piena.bytes)
      # I due modi di non avere risultati — filtro legittimo senza righe e identificativo ignoto —
      # costano lo stesso: l'ignoto non apre una strada diversa.
      expect(vuoto.bytes).to be_within(ignoto.bytes * 0.05).of(ignoto.bytes)
    end

    it "la stessa richiesta dopo una connessione interrotta consegna lo stesso frammento" do
      elenco = popola(3)
      volume = { ticket: elenco.size }
      primo = misura_frame("riconnessione", volume: volume)
      corpo_primo = response.body
      secondo = allow_n_plus_one { misura_frame("riconnessione", volume: volume) }

      # Il client che ha perso la risposta rifà lo stesso GET: stesse letture, stesso contenuto.
      expect(secondo.queries).to eq(primo.queries)
      elenco.each { |ticket| expect(response.body).to include(ticket.code) }
      # I byte non tornano identici al singolo carattere: ogni risposta porta un nonce CSP nuovo, e
      # l'intestazione lo ripete su ogni preload. L'uguaglianza che conta è entro l'uno per cento.
      expect(secondo.bytes).to be_within(corpo_primo.bytesize * 0.01).of(corpo_primo.bytesize)
    end

    it "con permessi ridotti il frame non mostra più della pagina intera" do
      cliente = create(:account)
      visibile = nil
      fuori_perimetro = nil
      allow_n_plus_one do
        altro_progetto = create(:project, organization: org)
        visibile = create(:ticket, organization: org, project: project, status: status,
                          priority: priority, reporter: reporter)
        fuori_perimetro = create(:ticket, organization: org, project: altro_progetto, status: status,
                                 priority: priority, reporter: reporter)
        create(:membership, account: cliente, organization: org, role: :customer)
        create(:project_membership, account: cliente, project: project)
      end
      post login_path, params: { email: cliente.email, password: "Secret123!" }

      esito = comparable_version("permessi_ridotti", volume: { ticket: 2 },
                        intera: -> { get list_member_tickets_path },
                        pezzo: lambda {
                          get list_member_tickets_path, headers: frame_header("tickets-results")
                        })

      # Il pezzo non è una scorciatoia per vedere di più: stesso perimetro della pagina intera.
      expect(esito[:corpo_intero]).to include(visibile.code)
      expect(esito[:corpo_intero]).not_to include(fuori_perimetro.code)
      expect(esito[:corpo_pezzo]).to include(visibile.code)
      expect(esito[:corpo_pezzo]).not_to include(fuori_perimetro.code)
    end

    it "il registro dichiara ambiente, revisione, volume e numerosità senza raccogliere contenuti" do
      elenco = popola(2)
      comparable_version("filtro", volume: { ticket: elenco.size },
                intera: -> { get list_member_tickets_path },
                pezzo: -> { get list_member_tickets_path, headers: frame_header("tickets-results") })

      documento = registro.document
      expect(documento["ambiente"]).to eq(App::Version.environment)
      expect(documento["revisione"]).to include("sha", "tag", "ruby_version", "rails_version")
      expect(documento["impostazione"]).to include("righe_per_pagina" => Pagination::DEFAULT_PER)
      expect(documento["numerosità"].values.sum).to be >= 2
      expect(documento["campioni"].first.keys)
        .to include("volume", "richieste", "byte", "letture", "scritture", "righe_lette", "millisecondi")
      # Il volume è del CAMPIONE: questi due sono stati presi su due ticket e lo dicono, qualunque
      # quantità abbiano usato gli altri esempi dello stesso giro.
      expect(documento["campioni"].last(2).map { |campione| campione["volume"] })
        .to all(eq("ticket" => 2))
      expect(documento["volumi_osservati"]["ticket"]).to include("min", "max")

      # Il registro sono numeri: nessun titolo, nessun indirizzo di posta, nessun corpo di risposta.
      serializzato = JSON.generate(documento)
      expect(serializzato).not_to include(account.email)
      elenco.each { |ticket| expect(serializzato).not_to include(ticket.title) }

      percorso = registro.write!
      expect(percorso.exist?).to be true
      expect(JSON.parse(percorso.read)["registro"]).to eq("aggiornamenti-parziali-richieste")
    end

    it "il registro rifiuta gli ambienti dove i dati sono quelli veri" do
      expect { PartialUpdate::Ledger.new(name: "prova", environment: "production") }
        .to raise_error(ArgumentError, /produzione/)
    end

    it "il registro accetta solo operazioni e canali dell'elenco chiuso" do
      # La difesa contro i dati personali è nella forma del metodo: un titolo non può entrarci.
      misura = { volume: { ticket: 1 }, requests: 1, bytes: 1, milliseconds: 1.0 }
      expect { registro.record(operation: ticket.title, channel: "frame", **misura) }
        .to raise_error(ArgumentError, /operazione sconosciuta/)
      expect { registro.record(operation: "filtro", channel: "websocket", **misura) }
        .to raise_error(ArgumentError, /canale sconosciuto/)
      expect { registro.record(operation: "filtro", channel: "frame", **misura.merge(volume: { titolo: 1 })) }
        .to raise_error(ArgumentError, /misura di volume sconosciuta/)
    end
  end
end
