# frozen_string_literal: true

require "rails_helper"

# CYRA-825 — smaltire le approvazioni senza rifare il contorno della pagina.
#
# Prima ogni decisione era un redirect a pagina intera, e il commento del controller ne diceva il
# motivo: i conteggi vivono nell'intestazione, fuori da qualunque riquadro, e sostituire la sola riga
# li avrebbe lasciati fermi. Qui quel confine viene spostato, non aggirato: il riquadro comprende
# INTESTAZIONE, esito della decisione e corpo, quindi si aggiornano insieme o non si aggiorna niente.
#
# Cosa presidia questo file: che il riquadro esista e contenga tutte e tre le parti; che la risposta
# al solo riquadro sia la stessa pagina senza contorno; che le decisioni — singole e in blocco —
# continuino a portarsi dietro filtri, messaggi ed esiti; e la misura, che è metà della Definition of
# Done: quanto si risparmia davvero e su cosa (byte, non database).
RSpec.describe "Member::Home::Approvals — il riquadro operativo", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:frame) { Member::Home::ApprovalsController::WORK_FRAME }
  let(:frame_headers) { { "Turbo-Frame" => frame } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def review_ticket(**attributes)
    create(:ticket, organization: org, project: project,
                    status: create(:ticket_status, :in_review, organization: org), reviewer: owner, **attributes)
  end

  # Il pezzo di HTML compreso fra l'apertura e la chiusura del riquadro: serve a distinguere «sta
  # nella pagina» da «sta DENTRO il riquadro», che è tutta la differenza fra un conteggio che si
  # aggiorna con la decisione e uno che resta fermo.
  def dentro_al_riquadro(body)
    # L'identificativo, non l'inizio del tag: gli attributi escono in ordine alfabetico e `id` non è
    # il primo. CYRA-899 — the board rows carry their own preview frames, so the closing tag is found
    # by counting nesting, not by taking the first one.
    apertura = body.index(%(id="#{frame}"))
    return "" if apertura.nil?

    depth = 1
    body.to_enum(:scan, %r{<turbo-frame\b|</turbo-frame>}).each do
      match = Regexp.last_match
      next if match.begin(0) < apertura

      depth += match[0].start_with?("</") ? -1 : 1
      return body[apertura...match.begin(0)] if depth.zero?
    end
    body[apertura..]
  end

  # Il numero scritto dentro una pill di conteggio: il valore sta in uno span monospazio subito dopo
  # l'etichetta, e leggerlo per intero è l'unico modo di dire «il conteggio è sceso» senza incrociare
  # per caso un altro numero della pagina.
  def conteggio(html, test_id)
    da = html.index(%(data-test="#{test_id}"))
    return nil if da.nil?

    html[da, 400][/font-semibold[^>]*>(\d+)</, 1]&.to_i
  end

  # Le query vere della richiesta: quelle di schema e quelle servite dalla cache non contano.
  def query_di
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:cached] || payload[:name].to_s.in?(%w[SCHEMA TRANSACTION])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  describe "la pagina intera" do
    it "tiene intestazione, esito e corpo dentro lo stesso riquadro" do
      review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path

      riquadro = dentro_al_riquadro(response.body)
      expect(riquadro).to include('data-test="approvals-header"')
      expect(riquadro).to include('data-test="approvals-phase-counters"')
      expect(riquadro).to include('data-test="approvals-board"')
    end

    # Il contenitore dei messaggi è `fixed` in fondo a destra: dove sta nel documento non cambia dove
    # si vede, ma cambia se una decisione può portarne uno nuovo. Dentro il riquadro sì; nel contorno
    # resterebbe quello di prima. Uno solo: due elementi con lo stesso identificativo sono un DOM
    # rotto, e chi risponde in turbo_stream (CYRA-828) ne colpirebbe uno a caso.
    it "porta dentro il riquadro il contenitore dei messaggi, una volta sola" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      expect(response.body.scan('id="flash-container"').size).to eq(1)
      expect(dentro_al_riquadro(response.body)).to include('id="flash-container"')
    end

    # `autoscroll` non porta in vista il riquadro: porta in vista il suo PRIMO FIGLIO. Se lì ci
    # finisse il contenitore dei messaggi — che è `fixed`, quindi già nel riquadro visibile — non si
    # scorrerebbe niente, e una decisione presa in fondo alla plancia lascerebbe lo sguardo a metà
    # della successiva. `space-y-6` dice la stessa cosa da un'altra parte: mette il margine sopra
    # ogni figlio tranne il primo, e davanti all'intestazione le avrebbe aggiunto uno spazio che
    # prima non c'era.
    it "apre il riquadro con l'intestazione, non col contenitore dei messaggi" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      riquadro = dentro_al_riquadro(response.body)
      expect(riquadro.index('data-test="approvals-header"')).to be < riquadro.index('id="flash-container"')
    end

    # L'elenco di ciò che va avanti da solo è l'altra resa della stessa pagina: se restasse fuori dal
    # riquadro, tornare in coda da lì ricadrebbe nel comportamento vecchio senza che nessuno se ne
    # accorga.
    it "vale anche per l'elenco di ciò che va avanti da solo" do
      ticket = create(:ticket, organization: org, project: project)
      create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago,
                              triaged_at: 1.day.ago)
      sign_in(owner)

      get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)

      expect(dentro_al_riquadro(response.body)).to include('data-test="approvals-count-in-flight"')
    end
  end

  describe "la richiesta del solo riquadro" do
    it "risponde con la stessa pagina senza il contorno" do
      review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path, headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("<!DOCTYPE html>")
      expect(response.body).not_to include('data-test="skip-link"')
      expect(dentro_al_riquadro(response.body)).to include('data-test="approvals-board"')
    end

    # Il riquadro si riconosce dall'intestazione che manda Turbo, MAI da un parametro: l'indirizzo
    # che si condivide resta quello della pagina intera.
    it "un altro riquadro non spegne il contorno" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path, headers: { "Turbo-Frame" => "un-altro-riquadro" }

      expect(response.body).to include("<!DOCTYPE html>")
    end

    # La metà misurata della Definition of Done. Il risparmio è di HTML — barra laterale, menu,
    # notifiche, presenze — e va detto per quello che è: le query dell'area operativa restano tutte,
    # perché coda, plancia e conteggi si costruiscono esattamente come prima.
    it "pesa la metà della pagina intera senza risparmiare sul database" do
      # Le righe si creano in blocco: l'N+1 è della fabbrica (numero del ticket, appartenenza del
      # reporter), non della richiesta che si sta misurando.
      allow_n_plus_one { 3.times { |i| review_ticket(title: "Riga #{i}") } }
      sign_in(owner)
      # The settings row is created on first read: made here so the full page, measured first, does not pay for it.
      Settings::Global.instance

      query_intera = query_di { get member_home_approvals_path }
      byte_interi = response.body.bytesize
      query_riquadro = query_di { get member_home_approvals_path, headers: frame_headers }
      byte_riquadro = response.body.bytesize

      expect(byte_riquadro).to be < (byte_interi / 2)
      # 13: the layout reads the organization AI settings once per page (CYRA-914).
      expect(query_intera - query_riquadro).to be <= 13
    end
  end

  describe "dopo una decisione" do
    # Scenario 1 del ticket: conteggi, elenco e dettaglio scendono INSIEME. Il totale è la prova più
    # semplice che l'intestazione non è rimasta indietro.
    it "il conteggio scende insieme alla decisione successiva che si apre" do
      create(:ticket_status, :done, organization: org)
      prima = review_ticket(title: "Prima")
      prima.update_column(:updated_at, 1.year.ago)
      seconda = review_ticket(title: "Seconda")
      sign_in(owner)

      get member_home_approvals_path, headers: frame_headers
      expect(dentro_al_riquadro(response.body).scan('data-test="approvals-board-row"').size).to eq(2)

      post member_home_approvals_decision_path, params: { item: "review:#{prima.id}", decision: "approve" },
                                                headers: frame_headers
      follow_redirect!(headers: frame_headers)

      riquadro = dentro_al_riquadro(response.body)
      expect(response.body).not_to include("<!DOCTYPE html>")
      expect(conteggio(riquadro, "approvals-count-total")).to eq(1)
      expect(riquadro).to include('data-test="approvals-detail"')
      expect(riquadro).to include(seconda.code)
    end

    it "l'errore di una decisione arriva come messaggio dentro il riquadro" do
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path(state: "review"),
           params: { item: "review:#{ticket.id}", decision: "reject" }, headers: frame_headers
      follow_redirect!(headers: frame_headers)

      riquadro = dentro_al_riquadro(response.body)
      expect(riquadro).to include('data-test="flash-alert"')
      expect(riquadro).to include('data-test="approvals-board"')
      expect(ticket.reload.status.review_gate?).to be(true)
    end

    # Scenario 2 del ticket: la richiesta è stata decisa altrove mentre la si guardava. Un esito
    # chiaro, nessuna seconda decisione, e i filtri restano accesi.
    it "una richiesta già decisa altrove lo dice senza decidere due volte e senza perdere i filtri" do
      done = create(:ticket_status, :done, organization: org)
      altrui = review_ticket(title: "Decisa altrove")
      sign_in(owner)
      altrui.update!(status: done)

      post member_home_approvals_decision_path(state: "review", project: project.key),
           params: { item: "review:#{altrui.id}", decision: "approve" }, headers: frame_headers

      expect(response).to redirect_to(member_home_approvals_path(state: "review", project: project.key))
      follow_redirect!(headers: frame_headers)
      expect(dentro_al_riquadro(response.body)).to include('data-test="flash-alert"')
    end

    # I filtri viaggiano nell'indirizzo dell'azione, non solo nella memoria per-indirizzo: senza,
    # decidere con un progetto acceso riscriveva la memoria col solo stato e la coda si riallargava.
    it "porta con sé anche progetto e agente, non solo lo stato" do
      create(:ticket_status, :done, organization: org)
      mio = review_ticket(title: "Del progetto")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{mio.id}", project: project.key)

      expect(response.body).to include("project=#{CGI.escape(project.key)}")
      expect(response.body).to include('data-test="approvals-decision"')
    end
  end

  describe "l'accettazione in blocco" do
    it "porta il resoconto dentro il riquadro, coi conteggi già scesi" do
      create(:ticket_status, :done, organization: org)
      primo = review_ticket
      secondo = review_ticket
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: [ "review:#{primo.id}", "review:#{secondo.id}" ] },
                                            headers: frame_headers
      follow_redirect!(headers: frame_headers)

      riquadro = dentro_al_riquadro(response.body)
      expect(riquadro).to include('data-test="flash-notice"')
      expect(riquadro).to include('data-test="approvals-empty"')
      expect(primo.reload.status.category).to eq("done")
    end

    # Una che passa e una che no: il resoconto è UN messaggio solo che dice tutto, e deve arrivare
    # dentro il riquadro insieme ai conteggi già scesi di uno. Senza, chi ha premuto su venti righe
    # non saprebbe che una non è passata.
    it "l'esito parziale arriva dentro il riquadro, non si perde per strada" do
      create(:ticket_status, :done, organization: org)
      buono = review_ticket
      rotto = review_ticket
      allow(Home::Approvals::Decide).to receive(:call).and_call_original
      allow(Home::Approvals::Decide).to receive(:call).with(hash_including(key: "review:#{rotto.id}"))
                                                     .and_raise(ActiveRecord::StatementTimeout, "database is locked")
      sign_in(owner)

      # La risoluzione per-card È il gate (BulkApprove#resolve → Detail, una per chiave): con
      # l'eccezione di mezzo le due risoluzioni restano attaccate e Prosopite le vede vicine.
      allow_n_plus_one do
        post member_home_approvals_bulk_path, params: { keys: [ "review:#{rotto.id}", "review:#{buono.id}" ] },
                                              headers: frame_headers
      end
      follow_redirect!(headers: frame_headers)

      riquadro = dentro_al_riquadro(response.body)
      expect(riquadro).to include('data-test="flash-alert"')
      expect(riquadro.scan('data-test="approvals-board-row"').size).to eq(1)
      expect(buono.reload.status.category).to eq("done")
    end

    it "il modulo dell'accettazione in blocco porta i filtri accesi" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path(state: "review", project: project.key)

      # L'indirizzo sta in un attributo HTML, dove la `&` è scritta `&amp;`.
      expect(response.body)
        .to include(CGI.escapeHTML(member_home_approvals_bulk_path(state: "review", project: project.key)))
    end
  end

  # Se una risposta al riquadro NON ridefinisse il riquadro, Turbo non troverebbe cosa sostituire e
  # rifarebbe la stessa richiesta a pagina intera: la decisione andrebbe a buon fine lo stesso, ma il
  # costo raddoppierebbe in silenzio. Vale per tutte le rese della pagina, vuota compresa.
  describe "ogni risposta al riquadro ridefinisce il riquadro" do
    {
      "con la plancia piena" => ->(_) { {} },
      "con una richiesta aperta" => ->(ticket) { { item: "review:#{ticket.id}" } },
      "con la coda vuota" => ->(_) { { state: "clarification" } }
    }.each do |caso, parametri|
      it caso do
        ticket = review_ticket
        sign_in(owner)

        get member_home_approvals_path(**parametri.call(ticket)), headers: frame_headers

        expect(response.body).to include(%(id="#{frame}"))
      end
    end
  end

  describe "il contorno resta quello di prima" do
    # Senza Turbo (e senza JS) non cambia niente: la decisione è un POST che redirige a una pagina
    # intera. È il fallback che tiene in piedi la pagina anche quando il riquadro non esiste.
    it "senza il riquadro la decisione ricarica la pagina intera" do
      create(:ticket_status, :done, organization: org)
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path, params: { item: "review:#{ticket.id}", decision: "approve" }
      follow_redirect!

      expect(response.body).to include("<!DOCTYPE html>")
      expect(response.body).to include('data-test="skip-link"')
    end

    it "chi decide dalla home ci torna, riquadro o no" do
      create(:ticket_status, :done, organization: org)
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path(return_to: "home"),
           params: { item: "review:#{ticket.id}", decision: "approve" }

      expect(response).to redirect_to(root_path)
    end
  end
end
