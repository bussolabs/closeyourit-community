# frozen_string_literal: true

require "rails_helper"

# CYRA-827 — la scheda progetto smette di essere un blocco unico.
#
# La panoramica mette insieme la lista ticket, la fascia di salute, gli ambienti, i rilasci, gli
# strumenti di monitoring, l'uptime e la cronologia completa del progetto. Sfogliare i ticket
# ricostruiva tutto: la cronologia veniva materializzata per intero (`.to_a`, senza limite) a ogni
# cambio pagina, e con lei le raccolte e gli aggregati che con quel filtro non c'entrano.
#
# Qui si prova il confine, non l'impressione: la richiesta della lista dentro il suo frame NON legge
# gli eventi né gli aggregati, la cronologia si chiede per conto suo ed è paginata, e la panoramica
# continua a mostrare l'ultimo evento. Il costo evitato — byte e letture, tenuti distinti — è misurato
# nel blocco in fondo con lo stesso metro di CYRA-826.
RSpec.describe "Caricamento selettivo della scheda progetto", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def frame_header(nome) = { "Turbo-Frame" => nome }

  def queries_during
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    queries
  end

  # I ticket di massa: creare N ticket ripete la lettura del progetto (numerazione) e della
  # membership (isolamento tenant) — query di fixture, non del codice sotto misura.
  def crea_ticket(quanti, **attrs)
    allow_n_plus_one do
      create_list(:ticket, quanti, organization: org, project: project, status: status,
                  priority: priority, **attrs)
    end
  end

  describe "Scenario 1 — cambiare pagina o filtro ai ticket" do
    it "la panoramica dichiara il frame della lista e non materializza la cronologia" do
      crea_ticket(2)
      allow_n_plus_one { create_list(:activity_event, 3, subject: project, organization: org) }

      sql = queries_during { get member_project_path(project) }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="project-tickets-results"')
      # Gli eventi si leggono ancora, ma soltanto l'ultimo: nessuna lettura senza limite.
      letture_eventi = sql.grep(/SELECT "activity_events"\.\*/)
      expect(letture_eventi).to all(match(/LIMIT/))
    end

    it "la richiesta del frame non rilegge cronologia, aggregati e raccolte del progetto" do
      crea_ticket(2)
      allow_n_plus_one { create_list(:activity_event, 3, subject: project, organization: org) }

      sql = queries_during do
        get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")
      end

      expect(response).to have_http_status(:ok)
      # La cronologia del progetto non viene toccata affatto.
      expect(sql.grep(/FROM "activity_events"/)).to be_empty
      # Né gli aggregati della fascia salute, né le raccolte della colonna destra.
      expect(sql.grep(/FROM "errors_groups"/)).to be_empty
      expect(sql.grep(/FROM "logs_entries"/)).to be_empty
      expect(sql.grep(/FROM "metrics_groups"/)).to be_empty
      expect(sql.grep(/FROM "projects_releases"/)).to be_empty
      expect(sql.grep(/FROM "knowledge_books"/)).to be_empty
      expect(sql.grep(/FROM "uptime_monitors"/)).to be_empty
    end

    it "il frame consegna il pezzo senza il layout della pagina" do
      crea_ticket(2)

      get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="project-tickets-results"')
      expect(response.body).not_to include('id="main-content"')
      # La cornice della panoramica resta fuori: il frame porta la lista e ciò che dipende dal filtro.
      expect(response.body).not_to include('data-test="project-audit"')
      expect(response.body).not_to include('data-test="project-tickets-title"')
    end

    it "cambiare pagina dentro il frame consegna le righe della pagina chiesta" do
      elenco = crea_ticket(18)

      get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")
      prima = response.body
      get member_project_path(project, ft: 1, page: 2), headers: frame_header("project-tickets-results")

      expect(response).to have_http_status(:ok)
      expect(prima.scan('data-test="project-ticket-row"').size).to eq(15)
      expect(response.body.scan('data-test="project-ticket-row"').size).to eq(3)
      expect(response.body).to include('data-test="project-tickets-pagination"')
      # Le tre righe della seconda pagina non erano nella prima.
      ultimi = elenco.sort_by(&:created_at).first(3)
      ultimi.each { |ticket| expect(response.body).to include(ticket.code) }
    end

    it "il filtro dentro il frame aggiorna righe e conteggio, che dal filtro dipendono" do
      altro_status = create(:ticket_status, organization: org)
      dentro = crea_ticket(1).first
      fuori = crea_ticket(1, status: altro_status).first

      get member_project_path(project, status_id: [ status.id ]),
          headers: frame_header("project-tickets-results")

      expect(response.body).to include(dentro.code)
      expect(response.body).not_to include(fuori.code)
      expect(response.body).to include('data-test="project-tickets-toolbar"')
      expect(response.body).to include(I18n.t("pagination.info", from: 1, to: 1, total: 1))
    end

    it "un filtro senza risultati resta dentro il frame, con la via d'uscita" do
      crea_ticket(1)
      senza_ticket = create(:ticket_status, organization: org)

      get member_project_path(project, status_id: [ senza_ticket.id ]),
          headers: frame_header("project-tickets-results")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="project-tickets-results"')
      expect(response.body).to include('data-test="project-tickets-no-match"')
      expect(response.body).to include('data-test="project-tickets-toolbar-reset"')
    end

    it "il link a un ticket esce dal frame invece di aprirsi dentro la lista" do
      ticket = crea_ticket(1).first

      get member_project_path(project)

      riga = Nokogiri::HTML(response.body).at_css("[data-test='project-ticket-link']")
      expect(riga["href"]).to eq(member_ticket_path(ticket))
      expect(riga["data-turbo-frame"]).to eq("_top")
    end

    it "il codice del ticket non va a capo quando accanto c'è l'indicatore dell'automazione" do
      crea_ticket(1)

      get member_project_path(project)

      cella = Nokogiri::HTML(response.body).at_css("[data-test='project-ticket-link']").ancestors("td").first
      expect(cella["class"].split).to include("whitespace-nowrap")
    end

    it "lo stesso indirizzo aperto senza frame resta una pagina intera condivisibile" do
      dentro = crea_ticket(1).first

      get member_project_path(project, page: 1, status_id: [ status.id ])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="main-content"')
      expect(response.body).to include('data-test="project-audit"')
      expect(response.body).to include(dentro.code)
    end

    it "il frame non è una scorciatoia per vedere ticket fuori dal proprio perimetro" do
      cliente = create(:account)
      visibile = nil
      fuori_perimetro = nil
      allow_n_plus_one do
        create(:membership, account: cliente, organization: org, role: :customer)
        create(:project_membership, account: cliente, project: project)
        visibile = create(:ticket, organization: org, project: project, status: status, priority: priority)
        altro = create(:project, organization: org)
        fuori_perimetro = create(:ticket, organization: org, project: altro, status: status, priority: priority)
      end
      post login_path, params: { email: cliente.email, password: "Secret123!" }

      get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(visibile.code)
      expect(response.body).not_to include(fuori_perimetro.code)
    end

    it "senza sessione il frame della lista porta alla login, non a un riquadro muto" do
      crea_ticket(1)
      delete logout_path

      get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")

      # Un redirect: il riquadro non trova il proprio nome nella risposta e Turbo apre la login a
      # schermo intero. Una risposta 200 senza frame lascerebbe la lista ferma senza dire perché.
      expect(response).to redirect_to(login_path)
    end

    it "il frame di un progetto non visibile risponde come la pagina intera: non esiste" do
      altro = create(:project)

      get member_project_path(altro, ft: 1), headers: frame_header("project-tickets-results")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Scenario 2 — aprire la cronologia" do
    it "la panoramica tiene l'ultimo evento e rimanda il resto al frame" do
      ultima_persona = create(:account, name: "Ada Lovelace")
      vecchio = create(:activity_event, subject: project, organization: org, created_at: 2.days.ago)
      create(:activity_event, subject: project, organization: org, action: "updated",
             actor: ultima_persona, actor_name: ultima_persona.name, created_at: 1.hour.ago)

      get member_project_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="project-audit"')
      # L'ultimo evento è nel riepilogo: chi l'ha fatto e quando, senza aprire niente.
      expect(response.body).to include("Ada Lovelace")
      expect(response.body).to include('loading="lazy"')
      expect(response.body).to include(history_member_project_path(project))
      # La cronologia intera non è più nella pagina.
      expect(response.body).not_to include("activity-row-#{vecchio.id}")
    end

    it "la cronologia chiesta nel frame arriva senza il resto della pagina" do
      create(:activity_event, subject: project, organization: org)

      get history_member_project_path(project), headers: frame_header("project-history")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="project-history"')
      expect(response.body).not_to include('id="main-content"')
      expect(response.body).to include('data-test="activity-row"')
    end

    it "counts the events only when there are some: an empty history already says so" do
      get history_member_project_path(project), headers: frame_header("project-history")
      expect(response.body).to include('data-test="activity-empty"')
      expect(response.body).not_to include('data-test="activity-count"')

      create(:activity_event, subject: project, organization: org)
      get history_member_project_path(project), headers: frame_header("project-history")
      expect(response.body).to include('data-test="activity-count"')
    end

    # `per` passa dall'allowlist di Pagination (CYRA-408): un numero fuori elenco cade sul default,
    # quindi la pagina 2 si prova con la densità più piccola che l'allowlist ammette.
    it "la cronologia si sfoglia a pagine, dalla più recente" do
      vecchio = create(:activity_event, subject: project, organization: org, created_at: 12.hours.ago)
      recenti = allow_n_plus_one do
        create_list(:activity_event, 12, subject: project, organization: org, created_at: 1.hour.ago)
      end

      get history_member_project_path(project, per: 12), headers: frame_header("project-history")
      expect(response.body).to include("activity-row-#{recenti.first.id}")
      expect(response.body).not_to include("activity-row-#{vecchio.id}")

      get history_member_project_path(project, per: 12, page: 2), headers: frame_header("project-history")
      expect(response.body).to include("activity-row-#{vecchio.id}")
      expect(response.body).not_to include("activity-row-#{recenti.first.id}")
      expect(response.body).to include('data-test="project-history-pagination"')
    end

    it "la cronologia legge solo la pagina chiesta, non tutti gli eventi" do
      allow_n_plus_one { create_list(:activity_event, 14, subject: project, organization: org) }

      sql = queries_during do
        get history_member_project_path(project, per: 12), headers: frame_header("project-history")
      end

      expect(response).to have_http_status(:ok)
      righe = sql.grep(/SELECT "activity_events"\.\*/)
      expect(righe).not_to be_empty
      expect(righe).to all(match(/LIMIT/))
    end

    it "un progetto senza eventi lo dice, invece di lasciare il pannello vuoto" do
      get history_member_project_path(project), headers: frame_header("project-history")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="activity-empty"')
      expect(response.body).to include(I18n.t("ui.audit.empty"))
    end

    it "la cronologia è apribile anche a pagina intera: è la via di recupero del pannello" do
      evento = create(:activity_event, subject: project, organization: org)

      get history_member_project_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="main-content"')
      expect(response.body).to include("activity-row-#{evento.id}")
      # E da lì si torna al progetto.
      expect(response.body).to include(member_project_path(project))
    end

    it "la cronologia di un progetto non visibile non è accessibile" do
      altro = create(:project)

      get history_member_project_path(altro), headers: frame_header("project-history")

      expect(response).to have_http_status(:not_found)
    end

    it "senza sessione la cronologia porta alla login invece di un pannello muto" do
      delete logout_path

      get history_member_project_path(project), headers: frame_header("project-history")

      expect(response).to redirect_to(login_path)
    end
  end

  # CYRA-827 — il confronto MISURATO che la Definition of Done chiede, con il metro di CYRA-826:
  # richieste, byte consegnati, letture e scritture del database, tempo. Quattro numeri distinti.
  #
  # COSA SI SCOPRE: qui il risparmio è vero su ENTRAMBI i fronti, ed è la differenza con la lista
  # ticket globale (dove il frame rispedisce il layout e le letture restano identiche): la richiesta
  # del frame rinuncia al layout a mano e la action esce prima di calcolare cronologia, aggregati e
  # raccolte. Byte e letture scendono insieme.
  #
  # NESSUNA SOGLIA SUL TEMPO: in CI il tempo di parete dipende dalla macchina e dagli altri shard.
  # Si asserisce solo ciò che è deterministico a parità di dati; i millisecondi restano nel registro.
  # Si rilegge in `tmp/performance/scheda-progetto-caricamento-selettivo.json`.
  describe "Confronto misurato del lavoro evitato" do
    after(:context) { PartialUpdate.write!("scheda-progetto-caricamento-selettivo") }

    def impostazione_confronto
      { righe_per_pagina: Member::ProjectsController::TICKETS_PER_PAGE,
        eventi_per_pagina: Member::ProjectsController::HISTORY_PER_PAGE }
    end

    def registro = PartialUpdate.ledger("scheda-progetto-caricamento-selettivo", setup: impostazione_confronto)

    # Lo stesso contenuto chiesto due volte, una per canale. Per Prosopite il secondo giro ripete
    # ogni query del primo: è la misura, non un N+1 del prodotto.
    def comparable_version(operazione, volume:, intera:, pezzo:)
      misura_intera = measure_partial_update(registro, operation: operazione, channel: "drive",
                                             volume: volume, &intera)
      corpo_intero = response.body
      misura_pezzo = allow_n_plus_one do
        measure_partial_update(registro, operation: operazione, channel: "frame", volume: volume, &pezzo)
      end
      { intera: misura_intera, pezzo: misura_pezzo, corpo_intero: corpo_intero, corpo_pezzo: response.body }
    end

    it "sfogliare i ticket nel frame costa meno byte E meno letture della pagina intera" do
      elenco = crea_ticket(18)
      allow_n_plus_one { create_list(:activity_event, 6, subject: project, organization: org) }
      volume = { ticket: elenco.size, eventi: 6 }

      esito = comparable_version("navigazione_pagina", volume: volume,
                        intera: -> { get member_project_path(project, ft: 1, page: 2) },
                        pezzo: lambda {
                          get member_project_path(project, ft: 1, page: 2),
                              headers: frame_header("project-tickets-results")
                        })

      expect(response).to have_http_status(:ok)
      # Le righe consegnate sono le stesse: chiedere il pezzo non è mostrare di meno.
      expect(esito[:corpo_pezzo].scan('data-test="project-ticket-row"').size)
        .to eq(esito[:corpo_intero].scan('data-test="project-ticket-row"').size)
      expect(esito[:pezzo].bytes).to be < (esito[:intera].bytes * 0.5)
      # E il database lavora davvero di meno: è la metà che la sola sensazione di fluidità non prova.
      expect(esito[:pezzo].queries).to be < esito[:intera].queries
      # Sfogliare non scrive: la memoria dei filtri sta nella sessione. Le due colonne restano due.
      expect(esito[:pezzo].writes).to be_zero
    end

    # Il volume si passa a mano e non si conta al volo: una COUNT dentro l'esempio sarebbe una query
    # ripetuta a ogni misura, cioè rumore per la guardia N+1 proprio nel file che misura le query.
    def misura_frame(operazione, volume:)
      measure_partial_update(registro, operation: operazione, channel: "frame", volume: volume) do
        get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")
      end
    end

    it "le letture del frame non crescono con le righe mostrate (0, 1 e N)" do
      vuoto = misura_frame("volume_zero", volume: { ticket: 0 })
      crea_ticket(1)
      uno = allow_n_plus_one { misura_frame("volume_uno", volume: { ticket: 1 }) }
      crea_ticket(11)
      molti = allow_n_plus_one { misura_frame("volume_molti", volume: { ticket: 12 }) }

      expect(vuoto.queries).to be <= uno.queries
      # Nessuna riga si porta dietro la sua query: dodici righe costano quanto una.
      expect(molti.queries).to be <= uno.queries
      expect(molti.bytes).to be > uno.bytes
    end

    it "aprire la cronologia costa una frazione della panoramica, e non cresce con lo storico" do
      crea_ticket(3)
      allow_n_plus_one { create_list(:activity_event, 20, subject: project, organization: org) }
      volume = { ticket: 3, eventi: 20 }

      esito = comparable_version("cambio_scheda", volume: volume,
                        intera: -> { get member_project_path(project) },
                        pezzo: lambda {
                          get history_member_project_path(project, per: 12),
                              headers: frame_header("project-history")
                        })

      expect(response).to have_http_status(:ok)
      expect(esito[:corpo_pezzo]).to include('id="project-history"')
      expect(esito[:pezzo].bytes).to be < (esito[:intera].bytes * 0.5)
      expect(esito[:pezzo].queries).to be < esito[:intera].queries
      # Dodici righe per pagina: lo storico può crescere quanto vuole, la pagina no.
      expect(esito[:corpo_pezzo].scan('data-test="activity-row"').size).to eq(12)
    end

    it "la stessa richiesta ripetuta dopo una connessione interrotta consegna lo stesso frammento" do
      elenco = crea_ticket(3)
      volume = { ticket: elenco.size }

      primo = measure_partial_update(registro, operation: "riconnessione", channel: "frame",
                                     volume: volume) do
        get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")
      end
      corpo_primo = response.body
      secondo = allow_n_plus_one do
        measure_partial_update(registro, operation: "riconnessione", channel: "frame",
                               volume: volume) do
          get member_project_path(project, ft: 1), headers: frame_header("project-tickets-results")
        end
      end

      expect(secondo.queries).to eq(primo.queries)
      elenco.each { |ticket| expect(response.body).to include(ticket.code) }
      # I byte non tornano identici al singolo carattere: ogni risposta può portare un nonce nuovo.
      # L'uguaglianza che conta è entro l'uno per cento.
      expect(secondo.bytes).to be_within(corpo_primo.bytesize * 0.01).of(corpo_primo.bytesize)
    end
  end
end
