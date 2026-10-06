# frozen_string_literal: true

require "rails_helper"

# CYAU-88 — UI host-centric: /member/agents elenca gli HOST (i Mac) e la loro attività,
# non i 5 agenti tipizzati (che restano nel DB, rimossi a CYAU-85). Certificazione spostata
# qui dalle ex "Installazioni".
RSpec.describe "Member::Agents (host-centric)", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  # Host online = ultimo heartbeat entro intervallo+tolleranza (il monitor automator invia 2+1).
  def online_host(**attrs)
    create(:agent_host, organization:, last_heartbeat_at: 30.seconds.ago,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
  end

  def offline_host(**attrs)
    create(:agent_host, organization:, last_heartbeat_at: 10.minutes.ago,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
  end

  # CYRA-450: offline oltre la soglia di allarme (15') → "fermo".
  def stale_host(**attrs)
    create(:agent_host, organization:, last_heartbeat_at: 20.minutes.ago,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
  end

  describe "autorizzazione" do
    it "non autenticato → redirect login" do
      get member_agents_path
      expect(response).to redirect_to(login_path)
    end

    it "membro senza agents.view → redirect" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      sign_in(member)
      get member_agents_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET index (lista host)" do
    before { sign_in(owner) }

    # CYRA-924 — the host list is paged like every other table, with the page footer.
    it "shows one page of hosts with the page footer" do
      13.times { |i| online_host(hostname: format("mac-%02d", i)) }

      get member_agents_path, params: { sort: "host" }
      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='agents-pagination']")
      expect(html).to have_text("mac-11")
      expect(html).to have_no_text("mac-12")

      get member_agents_path, params: { sort: "host", page: 2 }
      expect(Capybara.string(response.body)).to have_text("mac-12")
    end

    it "mostra gli host con i conteggi" do
      online_host(hostname: "mac-online")
      offline_host(hostname: "mac-offline")

      get member_agents_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("mac-online", "mac-offline")
      expect(response.body).to include('data-test="agents-counts"')
      expect(response.body).not_to include("Triage typed-agent")
    end

    it "mostra l'attività corrente (ticket · fase) dagli active_runs" do
      online_host(hostname: "mac-busy", host_status: "busy",
                  active_runs: [ { "ticket" => "CYRA-31", "phase" => "implementing", "runtime" => "claude" } ])

      get member_agents_path

      expect(response.body).to include("CYRA-31", "implementing")
    end

    it "filtra per ricerca su hostname" do
      online_host(hostname: "mac-alpha")
      online_host(hostname: "mac-beta")

      get member_agents_path, params: { q: "alpha" }

      expect(response.body).to include("mac-alpha")
      expect(response.body).not_to include("mac-beta")
    end

    it "empty-state quando non ci sono host, con l'azione per cominciare" do
      get member_agents_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="agents-empty"')
      expect(response.body).to include('data-test="agents-empty-cta"')
    end

    # CYRA-450 Scenario 2: un host acceso senza run non mostra più un trattino, ma lo stato di attesa.
    it "colonna Attività mai vuota: host acceso senza run → «In attesa di lavoro»" do
      online_host(hostname: "mac-idle", active_runs: [])

      get member_agents_path

      expect(response.body).to include(I18n.t("member.agents.activity.idle"))
    end

    it "shows on the row why the machine last stopped (CYRA-999)" do
      online_host(hostname: "mac-stopped", active_runs: [],
                  last_stops: [ { "action" => "lab", "state" => "waiting", "reason" => "empty ticket queue for LAB" } ])

      get member_agents_path

      expect(response.body).to include(I18n.t("member.agents.activity.last_stop", reason: "empty ticket queue for LAB"))
    end

    # CYRA-450 Scenario 1: un host fermo da oltre la soglia è in allarme (riga + badge) e conta tra i "fermi".
    it "host fermo → riga in allarme, badge dedicato e conteggio fermi" do
      stale_host(hostname: "mac-dead")
      online_host(hostname: "mac-alive")

      get member_agents_path

      expect(response.body).to include('data-stale="true"')
      expect(response.body).to include(I18n.t("member.agents.status.stale"))
      expect(response.body).to include('data-test="stat-stale"')
    end

    # D18 — "2 offline · 2 stale" reads like a sum: the stale count says it is part of the offline one.
    it "says on the stale count that it is part of the offline one" do
      stale_host(hostname: "mac-dead")

      get member_agents_path

      stale = Capybara.string(response.body).find("[data-test='stat-stale']")
      expect(stale[:title]).to eq(I18n.t("member.agents.stat_stale_title"))
    end

    it "isola gli host di un'altra organizzazione" do
      create(:agent_host, hostname: "foreign-host")

      get member_agents_path

      expect(response.body).not_to include("foreign-host")
    end

    # CYRA-453 — tolta dal menu, la pagina che fissa la versione delle competenze si raggiunge da qui:
    # è amministrazione, quindi il collegamento esiste solo per chi amministra le automazioni.
    describe "collegamento all'amministrazione delle versioni (CYRA-453)" do
      it "chi amministra lo vede" do
        get member_agents_path

        expect(response.body).to include('data-test="agents-skill-bundle-link"')
      end

      it "chi guarda soltanto non lo vede" do
        osservatore = create(:account)
        create(:membership, account: osservatore, organization:, role: :member)
        create(:account_permission, account: osservatore, organization:, permission_key: "agents.view")
        sign_in(osservatore)

        get member_agents_path

        expect(response.body).not_to include('data-test="agents-skill-bundle-link"')
      end
    end
  end

  describe "GET show (dettaglio host + attività)" do
    before { sign_in(owner) }

    # CYRA-1032 — three tabs: the overview with activity and performance, the work history, and the
    # machine details with its engine settings. Each tab renders only its own panels.
    describe "tabs" do
      it "opens on the overview: activity and performance, no history and no details" do
        host = online_host(hostname: "mac-tabs")

        get member_agent_path(host)

        body = response.body
        expect(body).to include('data-test="host-tab-overview"', 'data-test="host-tab-work"', 'data-test="host-tab-details"')
        expect(body).to include('data-test="host-activity"', 'data-test="host-performance"')
        expect(body).not_to include('data-test="host-worked-tickets"')
        expect(body).not_to include('data-test="host-facts"')
      end

      it "shows the work history on the work tab, with the period selector" do
        host = online_host(hostname: "mac-tab-work")

        get member_agent_path(host, tab: "work")

        body = response.body
        expect(body).to include('data-test="host-worked-tickets"', 'data-test="range-selector"')
        expect(body).not_to include('data-test="host-activity"')
        expect(body).not_to include('data-test="host-performance"')
      end

      it "shows the machine, its engines and its programs on the details tab" do
        host = online_host(hostname: "mac-tab-details")

        get member_agent_path(host, tab: "details")

        body = response.body
        expect(body).to include('data-test="host-facts"', 'data-test="host-engines"')
        expect(body).not_to include('data-test="host-activity"')
        expect(body).not_to include('data-test="host-performance"')
      end

      # CYRA-1034 — the details tab says which installed programs have a newer release.
      it "marks the programs that have an update on the details tab" do
        allow(Agents::RuntimeVersions).to receive(:status).and_return(nil)
        allow(Agents::RuntimeVersions).to receive(:status).with("claude", "2.1.289").and_return(latest: "2.1.291", outdated: true)
        allow(Agents::RuntimeVersions).to receive(:status).with("codex", "0.160.1").and_return(latest: "0.160.1", outdated: false)
        host = online_host(hostname: "mac-versions", runtimes: [ { "name" => "claude", "version" => "2.1.289" },
                                                                 { "name" => "codex", "version" => "0.160.1" },
                                                                 { "name" => "jq", "version" => "jq-1.7" } ])

        get member_agent_path(host, tab: "details")

        body = response.body
        expect(body).to include(I18n.t("member.agents.show.runtime_col_latest"), "2.1.291")
        expect(body.scan('data-test="host-runtime-latest"').size).to eq(2)
        expect(body.scan('data-test="host-runtime-outdated"').size).to eq(1)
      end

      it "falls back to the overview for an unknown tab" do
        host = online_host(hostname: "mac-tab-unknown")

        get member_agent_path(host, tab: "nope")

        expect(response.body).to include('data-test="host-performance"')
      end
    end

    # CYRA-183: l'ELENCO viene dallo snapshot (include le run ferme, che non hanno lease vivo); il lease
    # è la fonte autorevole della fase in corso e il ticket risolto porta titolo e prodotti.
    it "mostra host, chip stato e la sezione Attività col ticket della run" do
      ticket = create(:ticket, organization:, title: "Sistemare la navbar", with_agent_workflow: true)
      host = online_host(hostname: "mac-1", active_runs: [ { "ticket" => ticket.code, "lease_health" => "active" } ])
      create(:agent_lease, :host_first, host:, ticket:, expires_at: 30.minutes.from_now)

      get member_agent_path(host)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("mac-1", ticket.code, "Sistemare la navbar")
      expect(response.body).to include('data-test="host-activity"')
      expect(response.body).to include('data-test="host-labels"')
    end

    it "mostra il percorso per fasi con quello in corso evidenziato" do
      ticket = create(:ticket, organization:, with_agent_workflow: true)
      host = online_host(hostname: "mac-steps", active_runs: [ { "ticket" => ticket.code } ])
      workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
      workflow.update!(triaged_at: 1.hour.ago)
      create(:agent_lease, :host_first, host:, ticket:, execution_phase: "planner", expires_at: 30.minutes.from_now)

      get member_agent_path(host)

      expect(response.body).to include('data-test="host-run-timeline"')
      # triage concluso, planner in corso: gli stati viaggiano come data-attribute, verificabili senza CSS.
      expect(response.body).to include('data-phase="triage" data-status="done"')
      expect(response.body).to include('data-phase="planner" data-status="current"')
      expect(response.body).to include('data-phase="autopilot" data-status="pending"')
    end

    # `agents.view` è org-level, la visibilità dei ticket è per-progetto: chi vede gli host ma non il
    # progetto non deve leggere titolo, ramo e PR. Il codice e il percorso restano (attività dell'host).
    it "anti-BOLA: per un ticket non visibile mostra il codice ma non titolo, link e prodotti" do
      foreign_project = create(:project, organization:)
      ticket = create(:ticket, organization:, project: foreign_project, title: "Titolo riservato")
      host = online_host(hostname: "mac-bola", active_runs: [ { "ticket" => ticket.code } ])
      workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
      attempt = create(:agent_attempt, workflow:, organization:)
      Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [ "Uno" ],
                           definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
      create(:agent_lease, :host_first, host:, ticket:, expires_at: 30.minutes.from_now)

      viewer = create(:account)
      create(:membership, organization:, account: viewer)
      create(:account_permission, account: viewer, organization:, permission_key: "agents.view", effect: :allow)
      sign_in(viewer)

      get member_agent_path(host)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ticket.code)
      expect(response.body).not_to include("Titolo riservato")
      expect(response.body).not_to include(member_ticket_path(ticket))
      expect(response.body).not_to include('data-test="host-run-products"')
      # Il percorso resta: è attività dell'host, non contenuto del ticket.
      expect(response.body).to include('data-test="host-run-timeline"')
    end

    # Lease creato prima del modello host-first: senza execution_phase la riga deve restare leggibile.
    it "lease senza fase: ripiega sulla fase pronta del workflow" do
      ticket = create(:ticket, organization:, with_agent_workflow: true)
      host = online_host(hostname: "mac-legacy", active_runs: [ { "ticket" => ticket.code } ])
      workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
      # Fase GIA' AVVIATA: `ready_execution_phase` qui e' nil (non e' piu' reclamabile) — la fase in corso
      # va dedotta dai timestamp, altrimenti nessun passaggio risulterebbe attivo.
      workflow.update!(triage_requested_at: 2.hours.ago, triage_started_at: 1.hour.ago, triaged_at: nil)
      create(:agent_lease, host:, ticket:, agent: "triage", execution_phase: nil, expires_at: 30.minutes.from_now)

      get member_agent_path(host)

      expect(response.body).to include('data-phase="triage" data-status="current"')
    end

    # Una run FERMA ha per definizione il lease scaduto: elencando per lease vivi sparirebbe proprio
    # quando va vista, e il badge `expired` non sarebbe mai raggiungibile.
    it "mostra le run ferme anche senza lease vivo, coi loro badge" do
      host = online_host(hostname: "mac-stalled")
      ticket = create(:ticket, organization:, with_agent_workflow: true)
      workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
      workflow.update!(triaged_at: 1.hour.ago)
      host.update!(active_runs: [ { "ticket" => ticket.code, "phase" => "implementing",
                                    "lease_health" => "expired", "stalled" => true } ])

      get member_agent_path(host)

      expect(response.body).to include(ticket.code)
      expect(response.body).to include('data-test="host-run-stalled"')
      expect(response.body).to include(I18n.t("member.agents.activity.lease_health.expired"))
      # Il percorso resta leggibile anche senza lease: la fase si deduce dai timestamp.
      expect(response.body).to include('data-phase="triage" data-status="done"')
    end

    # CYRA-498 — l'intestazione diceva «0 in esecuzione», il riquadro «nessuna attività» e sotto, in
    # piccolo, «Attempt attivi: 5». Chi legge non sa a quale dei tre credere.
    describe "i contatori dell'attività concordano" do
      it "una macchina ferma dice zero dappertutto" do
        host = online_host(hostname: "mac-ferma", active_runs: [])

        get member_agent_path(host)

        pagina = Nokogiri::HTML(response.body)
        expect(pagina.at_css("[data-test='host-running']").text).to include("0")
        expect(pagina.at_css("[data-test='host-slots']").text).to match(/\b0\//)
        expect(pagina.at_css("[data-test='host-activity-none']")).to be_present
      end

      it "una macchina al lavoro conta le stesse lavorazioni che elenca" do
        ticket = create(:ticket, organization:, with_agent_workflow: true)
        host = online_host(hostname: "mac-attiva", active_runs: [ { "ticket" => ticket.code } ])

        get member_agent_path(host)

        pagina = Nokogiri::HTML(response.body)
        expect(pagina.at_css("[data-test='host-running']").text).to include("1")
        expect(pagina.css("[data-test='host-run']").size).to eq(1)
        expect(pagina.at_css("[data-test='host-activity-none']")).to be_nil
      end

      it "i lavori aperti che la macchina non segnala diventano un avviso, non un numero che smentisce" do
        ticket = create(:ticket, organization:, with_agent_workflow: true)
        workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
        host = online_host(hostname: "mac-scollegata", active_runs: [])
        create(:agent_attempt, host:, workflow:, organization:, status: :running)

        get member_agent_path(host)

        avviso = Nokogiri::HTML(response.body).at_css("[data-test='host-unreported-work']")
        expect(avviso).to be_present
        expect(avviso.text).to include(I18n.t("member.agents.activity.unreported", count: 1))
        expect(response.body).not_to include("Attempt")
      end
    end

    it "mostra cosa la lavorazione ha prodotto" do
      ticket = create(:ticket, organization:, with_agent_workflow: true)
      host = online_host(hostname: "mac-products", active_runs: [ { "ticket" => ticket.code } ])
      workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
      attempt = create(:agent_attempt, workflow:, organization:)
      Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [ "Uno" ],
                           definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
      create(:agent_lease, :host_first, host:, ticket:, expires_at: 30.minutes.from_now)

      get member_agent_path(host)

      expect(response.body).to include('data-test="host-run-products"')
      expect(response.body).to include("v1")
    end

    it "host senza attività: sezione Attività vuota" do
      host = online_host(hostname: "mac-idle")

      get member_agent_path(host)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="host-activity"')
    end

    it "host di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:agent_host)

      get member_agent_path(foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-279 — la show mostrava solo il presente: chi guardava un agente non poteva sapere cosa
  # avesse lavorato, quanto ci mettesse, quanta parte del suo lavoro venisse respinta.
  # CYRA-451 — «di chi mi fido di più» è una domanda di confronto: due macchine sullo stesso
  # periodo, le stesse misure, una accanto all'altra.
  describe "GET compare" do
    before { sign_in(owner) }

    it "affianca due macchine sullo stesso periodo" do
      uno = online_host(hostname: "mac-uno")
      due = online_host(hostname: "mac-due")

      get compare_member_agents_path(host_ids: [ uno.id, due.id ], range: "7d")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="compare-table"')
      expect(response.body).to include("mac-uno", "mac-due")
      expect(response.body).to include('data-test="compare-range-7d"')
    end

    it "i conteggi dicono quante macchine e quale periodo, non la sigla cruda del periodo" do
      uno = online_host(hostname: "mac-uno")
      due = online_host(hostname: "mac-due")

      get compare_member_agents_path(host_ids: [ uno.id, due.id ], range: "7d")

      counts = Nokogiri::HTML(response.body).at_css('[data-test="agents-compare-counts"]').text.squish
      expect(counts).to include(I18n.t("member.agents.performance.compare.machines").downcase)
      expect(counts).to include(I18n.t("member.agents.performance.ranges.7d"))
      expect(counts).not_to include("7d")
    end

    it "i tempi confrontati dicono che sono mediane" do
      uno = online_host(hostname: "mac-uno")

      get compare_member_agents_path(host_ids: [ uno.id ])

      row = Nokogiri::HTML(response.body).at_css('[data-metric="host_time"]').text
      expect(row).to include(I18n.t("member.agents.performance.compare.median",
                                    label: I18n.t("member.agents.performance.host_time")))
    end

    it "senza scelta esplicita parte dalle prime due macchine" do
      online_host(hostname: "mac-alfa")
      online_host(hostname: "mac-beta")
      online_host(hostname: "mac-gamma")

      get compare_member_agents_path

      # La terza resta nel menu di scelta (serve a cambiarlo), ma non nella tabella del confronto.
      table = Nokogiri::HTML(response.body).at_css('[data-test="compare-table"]').text
      expect(table).to include("mac-alfa", "mac-beta")
      expect(table).not_to include("mac-gamma")
    end

    it "una macchina di un'altra organizzazione non entra nel confronto" do
      mia = online_host(hostname: "mac-mia")
      altra = create(:agent_host, organization: create(:organization), hostname: "mac-altrui")

      get compare_member_agents_path(host_ids: [ mia.id, altra.id ])

      expect(response.body).to include("mac-mia")
      expect(response.body).not_to include(altra.hostname)
    end

    it "senza il permesso di lettura non si apre" do
      sign_in(create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) })

      get compare_member_agents_path

      expect(response).to have_http_status(:forbidden).or have_http_status(:found)
    end
  end

  describe "GET show (storico e rendimento)" do
    before { sign_in(owner) }

    # Il ticket lo porta il workflow (che se lo crea da sé): passare un
    # ticket già fatto obbligherebbe a interrogarne il workflow, e sarebbe una query in più per
    # riga nel SETUP — rumore che il guard N+1 conterebbe come se fosse della pagina.
    def concluded(host:, workflow: nil, phase: "triage", status: :approved, seconds: 60, age: 1.hour)
      workflow ||= create(:agent_workflow, organization:)
      started = age.ago
      create(:agent_attempt, organization:, host:, workflow:, phase:, status:,
                             started_at: started, finished_at: started + seconds)
      workflow
    end

    it "mostra rendimento, tempi per passaggio e ticket lavorati" do
      host = online_host(hostname: "mac-stats")
      workflow = create(:agent_workflow, organization:)
      ticket = workflow.ticket
      ticket.update!(title: "Sistemare la navbar")
      concluded(host:, workflow:, phase: "triage", seconds: 100)
      concluded(host:, workflow:, phase: "planner", status: :review_failed, seconds: 200)

      get member_agent_path(host)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="host-performance"')
      expect(response.body).to include('data-test="host-phase-table"')
      expect(response.body).to include('data-test="range-selector"')
      # Un ticket, due passaggi: il totale dei tentativi non è il numero di ticket.
      expect(response.body).to include(">1<") # ticket lavorati
      expect(response.body).to include("5m 00s") # tempo dell'agente sul ticket: 100s + 200s

      get member_agent_path(host, tab: "work")
      expect(response.body).to include('data-test="host-worked-tickets"')
      expect(response.body).to include(ticket.code, "Sistemare la navbar")
    end

    # CYRA-499 — il tempo di lavorazione si può calcolare solo sulle lavorazioni CHIUSE. Finché non
    # ce n'è nessuna, il riquadro e la colonna sparivano dietro un trattino ripetuto su ogni riga:
    # ora non compaiono affatto, e il tempo dell'agente non viene scambiato per il tempo totale.
    it "senza lavorazioni chiuse non mostra né il riquadro né la colonna del tempo di lavorazione" do
      host = online_host(hostname: "mac-senza-chiusure")
      concluded(host:)

      get member_agent_path(host)

      expect(response.body).to include('data-test="perf-host-time"')
      expect(response.body).not_to include('data-test="perf-workflow-time"')

      get member_agent_path(host, tab: "work")
      expect(response.body).to include('data-test="worked-row"')
      expect(response.body).not_to include(I18n.t("member.agents.worked.col_workflow_time"))
    end

    it "con una lavorazione chiusa mostra riquadro, colonna e su quante lavorazioni è calcolato" do
      host = online_host(hostname: "mac-con-chiusure")
      done = create(:agent_workflow, organization:, triage_requested_at: 6.hours.ago, completed_at: 3.hours.ago)
      concluded(host:, workflow: done, age: 5.hours)

      get member_agent_path(host)

      expect(response.body).to include('data-test="perf-workflow-time"')
      expect(response.body).to include(I18n.t("member.agents.performance.workflow_median_caption",
                                              value: "3h 00m", count: 1))
      expect(response.body).to include(I18n.t("member.agents.worked.col_workflow_time"))
    end

    # Scenario 2 del ticket: due misure di tempo affiancate senza una parola che le distingua si
    # leggono a indovinare, e quella sbagliata passa per il tempo totale.
    it "spiega in pagina che cosa misura ciascuno dei due tempi" do
      host = online_host(hostname: "mac-legenda")
      done = create(:agent_workflow, organization:, triage_requested_at: 6.hours.ago, completed_at: 3.hours.ago)
      concluded(host:, workflow: done, age: 5.hours)

      get member_agent_path(host)

      expect(response.body).to include('data-test="perf-host-time-hint"', 'data-test="perf-workflow-time-hint"')
      expect(response.body).to include(I18n.t("member.agents.performance.host_time_legend"))
      expect(response.body).to include(I18n.t("member.agents.performance.workflow_time_legend"))
    end

    # CYRA-451 — i numeri erano onesti ma muti: nessun costo, nessuna tendenza, nessun elenco dietro
    # le celle. Qui si verifica che le quattro cose che mancavano ci siano.
    it "riporta il costo stimato del periodo con quante partenze ci stanno dietro" do
      host = online_host(hostname: "mac-cost")
      concluded(host:)
      create(:agent_limit_reservation, organization:, host:, estimated_cost: "1.5000")
      create(:agent_limit_reservation, organization:, host:, estimated_cost: "0.5000")

      get member_agent_path(host)

      expect(response.body).to include('data-test="perf-cost"')
      expect(response.body).to include("$2.00")
    end

    it "dichiara le partenze senza costo tracciato invece di sommare un totale parziale" do
      host = online_host(hostname: "mac-cost-partial")
      concluded(host:)
      create(:agent_limit_reservation, organization:, host:, estimated_cost: "1.0000")
      create(:agent_limit_reservation, organization:, host:, estimated_cost: nil)

      get member_agent_path(host)

      expect(response.body).to include(I18n.t("member.agents.performance.cost_partial", count: 1, untracked: 1))
    end

    it "senza nessun costo tracciato lo dice, invece di mostrare zero" do
      host = online_host(hostname: "mac-cost-none")
      concluded(host:)

      get member_agent_path(host)

      expect(response.body).to include(I18n.t("member.agents.performance.cost_unavailable"))
    end

    it "affianca alle metriche la variazione sul periodo precedente" do
      host = online_host(hostname: "mac-trend")
      concluded(host:, status: :approved, age: 2.days)
      concluded(host:, status: :rejected, age: 40.days)
      concluded(host:, status: :rejected, age: 45.days)

      get member_agent_path(host, range: "30d")

      # Il periodo prima aveva due lavori su due respinti, questo nessuno: la tendenza è in calo.
      expect(response.body).to include(I18n.t("member.agents.performance.trend.delta",
                                              value: "−#{I18n.t('member.agents.performance.trend.points', value: '100')}"))
    end

    it "sul periodo `all` non inventa una tendenza" do
      host = online_host(hostname: "mac-all")
      concluded(host:)

      get member_agent_path(host, range: "all")

      expect(response.body).not_to include(I18n.t("member.agents.performance.trend.flat"))
    end

    it "le celle del riepilogo per passaggio aprono le lavorazioni che ci stanno dietro" do
      host = online_host(hostname: "mac-drill")
      concluded(host:, phase: "autopilot", status: :stale)
      concluded(host:, phase: "autopilot", status: :approved)

      get member_agent_path(host)

      expect(response.body).to include('data-test="phase-cell-link"')
      expect(response.body).to include(ERB::Util.html_escape(member_agent_path(host, tab: "work", range: "30d", phase: "autopilot", outcome: "interrupted")))
    end

    it "filtrando per passaggio ed esito la lista mostra solo quelle lavorazioni" do
      host = online_host(hostname: "mac-filter")
      interrotta = concluded(host:, phase: "autopilot", status: :stale)
      approvata = concluded(host:, phase: "autopilot", status: :approved)

      get member_agent_path(host, tab: "work", phase: "autopilot", outcome: "interrupted")

      expect(response.body).to include(interrotta.ticket.code)
      expect(response.body).not_to include(approvata.ticket.code)
      expect(response.body).to include('data-test="worked-filter-chip"')
    end

    it "un filtro fuori vocabolario viene ignorato invece di svuotare la lista" do
      host = online_host(hostname: "mac-badfilter")
      workflow = concluded(host:, phase: "triage", status: :approved)

      get member_agent_path(host, tab: "work", phase: "non-esiste", outcome: "boh")

      expect(response.body).to include(workflow.ticket.code)
      expect(response.body).not_to include('data-test="worked-filter-chip"')
    end

    it "rende tutte e cinque le fasi, anche quelle mai eseguite" do
      host = online_host(hostname: "mac-phases")
      concluded(host:, phase: "triage")

      get member_agent_path(host)

      Agents::PhaseProfile::PHASES.each do |phase|
        expect(response.body).to include(%(data-phase="#{phase}"))
      end
    end

    it "il periodo governa i numeri e resta scegliibile anche quando è vuoto" do
      host = online_host(hostname: "mac-range")
      concluded(host:, age: 60.days)

      get member_agent_path(host)

      expect(response.body).to include('data-test="host-performance-empty"')
      expect(response.body).to include('data-test="range-selector"')

      get member_agent_path(host, range: "all")

      expect(response.body).not_to include('data-test="host-performance-empty"')
      expect(response.body).to include('data-test="host-phase-table"')
    end

    it "un periodo inventato nell'URL non rompe la pagina" do
      host = online_host(hostname: "mac-bad-range")
      concluded(host:)

      get member_agent_path(host, range: "'; DROP TABLE")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="host-phase-table"')
    end

    # Stesso gate della sezione Attività: il codice è attività dell'host, il titolo è contenuto del
    # ticket. Senza questo filtro chi vede gli agenti leggerebbe i titoli di progetti che non vede.
    it "anti-BOLA: di un ticket non visibile mostra il codice ma non titolo né link" do
      host = online_host(hostname: "mac-bola-stats")
      foreign_project = create(:project, organization:)
      ticket = create(:ticket, organization:, project: foreign_project, title: "Titolo riservato")
      concluded(host:, workflow: create(:agent_workflow, organization:, ticket:))

      viewer = create(:account)
      create(:membership, organization:, account: viewer)
      create(:account_permission, account: viewer, organization:, permission_key: "agents.view", effect: :allow)
      sign_in(viewer)

      get member_agent_path(host, tab: "work")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="worked-row"')
      expect(response.body).to include(ticket.code)
      expect(response.body).not_to include("Titolo riservato")
      expect(response.body).not_to include(member_ticket_path(ticket))
    end

    it "host senza storia: un messaggio, non una griglia di zeri" do
      host = online_host(hostname: "mac-no-history")

      get member_agent_path(host)

      expect(response.body).to include('data-test="host-performance-empty"')
      expect(response.body).not_to include('data-test="host-phase-table"')

      get member_agent_path(host, tab: "work")
      expect(response.body).to include('data-test="host-worked-empty"')
    end

    it "i tentativi ancora in corso non entrano nello storico" do
      host = online_host(hostname: "mac-running")
      create(:agent_attempt, organization:, host:, status: :running,
                             workflow: create(:agent_workflow, organization:), started_at: 5.minutes.ago)

      get member_agent_path(host)

      expect(response.body).to include('data-test="host-performance-empty"')
    end

    # Il guard N+1 è attivo su tutti i request spec: qui la richiesta resta scansionata, mentre le
    # tre lavorazioni di fixture no — crearle ripete per costruzione le query per-record delle
    # factory (numero del ticket, validazioni tenant), che non sono query della pagina.
    it "non interroga il database per riga (nessun N+1)" do
      host = online_host(hostname: "mac-n1")
      allow_n_plus_one { 3.times { concluded(host:) } }

      get member_agent_path(host, tab: "work")

      expect(response).to have_http_status(:ok)
      expect(response.body.scan('data-test="worked-row"').size).to eq(3)
    end
  end

  describe "certificazione (spostata dalle ex Installazioni)" do
    it "mostra il pulsante Certifica a chi gestisce, con host non certificato" do
      sign_in(owner)
      host = create(:agent_host, :uncertified, organization:)

      get member_agent_path(host)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="certify-host"')
      expect(response.body).to include('data-test="host-certification"')
    end

    it "certifica un host (agents.manage): redirect + certified_at/by settati" do
      sign_in(owner)
      host = create(:agent_host, :uncertified, organization:)

      post certify_member_agent_path(host), params: { confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host))
      expect(host.reload).to be_certified
      expect(host.certified_by).to eq(owner)
    end

    # CYRA-921, CYAU-226
    it "lets the machine name the engine that reviews its work" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      get member_agent_path(host, tab: "details")
      expect(response.body).to include('data-test="host-review-mode"')

      # A weaker review is a dangerous action: the first request asks for confirmation (CYRA-728).
      patch review_member_agent_path(host), params: { reviewer: "claude" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.effective_reviewer).to eq("codex")

      patch review_member_agent_path(host), params: { reviewer: "claude", confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host, tab: "details"))
      expect(host.reload.reviewer).to eq("claude")
    end

    it "refuses an unknown reviewer" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      patch review_member_agent_path(host), params: { reviewer: "nobody", confirm: "1" }

      expect(host.reload.effective_reviewer).to eq("codex")
    end

    it "says why OpenCode cannot review while the organization has no OpenRouter model" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      patch review_member_agent_path(host), params: { reviewer: "opencode", confirm: "1" }

      expect(flash[:alert]).to eq(I18n.t("member.agents.review.opencode_model_missing"))
      expect(host.reload).to be_follows_organization
    end

    it "keeps a following machine following when its pre-filled reviewer is saved unchanged" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      patch review_member_agent_path(host), params: { reviewer: "codex", confirm: "1" }

      expect(host.reload).to be_follows_organization
    end

    # CYAU-226: the reviewer is a name, so a new worker that was the reviewer hands the review to the old worker.
    it "keeps a different reviewer when the work moves to the engine that was reviewing" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      patch engine_member_agent_path(host), params: { work_engine: "codex", confirm: "1" }

      expect(host.reload).to have_attributes(work_engine: "codex", reviewer: "claude")
    end

    # CYRA-921
    it "lets Codex do the work, after confirmation" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      get member_agent_path(host, tab: "details")
      expect(response.body).to include('data-test="host-work-engine"')

      patch engine_member_agent_path(host), params: { work_engine: "codex" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.effective_work_engine).to eq("claude")

      patch engine_member_agent_path(host), params: { work_engine: "codex", confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host, tab: "details"))
      expect(host.reload.work_engine).to eq("codex")
    end

    it "refuses an unknown work engine" do
      sign_in(owner)
      host = create(:agent_host, organization:)

      patch engine_member_agent_path(host), params: { work_engine: "gemini", confirm: "1" }

      expect(host.reload.effective_work_engine).to eq("claude")
    end

    # CYAU-227
    it "shows that a machine follows the organization's choice" do
      sign_in(owner)
      create(:agent_automator_setting, organization:, work_engine: "codex", reviewer: "claude")
      host = create(:agent_host, organization:)

      get member_agent_path(host, tab: "details")

      expect(response.body).to include(I18n.t("member.agents.choice.follows"))
      expect(response.body).not_to include('data-test="host-follow-organization"')
    end

    it "sends a machine with its own choice back to following the organization, after confirmation" do
      sign_in(owner)
      host = create(:agent_host, organization:, work_engine: "codex", reviewer: "claude")

      get member_agent_path(host, tab: "details")
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.agents.choice.own")))
      expect(response.body).to include('data-test="host-follow-organization"')

      patch follow_organization_member_agent_path(host)
      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload).not_to be_follows_organization

      patch follow_organization_member_agent_path(host), params: { confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host, tab: "details"))
      expect(host.reload).to be_follows_organization
    end

    it "revoca la certificazione" do
      sign_in(owner)
      host = create(:agent_host, organization:, certified_at: Time.current, certified_by: owner)

      post decertify_member_agent_path(host), params: { confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host))
      expect(host.reload).not_to be_certified
    end

    context "senza agents.manage" do
      let(:plain_member) { create(:account) }

      before do
        create(:membership, account: plain_member, organization:, role: :member)
        sign_in(plain_member)
      end

      it "cannot change who reviews" do
        host = create(:agent_host, organization:)

        patch review_member_agent_path(host), params: { reviewer: "claude", confirm: "1" }

        expect(host.reload.effective_reviewer).to eq("codex")
      end

      it "cannot change who does the work" do
        host = create(:agent_host, organization:)

        patch engine_member_agent_path(host), params: { work_engine: "codex", confirm: "1" }

        expect(host.reload.effective_work_engine).to eq("claude")
      end

      it "cannot send a machine back to following the organization" do
        host = create(:agent_host, organization:, work_engine: "codex", reviewer: "claude")

        patch follow_organization_member_agent_path(host), params: { confirm: "1" }

        expect(host.reload).not_to be_follows_organization
      end

      it "non può certificare: host non certificato" do
        host = create(:agent_host, :uncertified, organization:)

        post certify_member_agent_path(host)

        expect(response).to have_http_status(:redirect)
        expect(host.reload).not_to be_certified
      end
    end
  end

  # CYRA-516 — una macchina dismessa restava in elenco per sempre: non c'era modo di toglierla,
  # né dalla pagina né dalla CLI. L'eliminazione porta con sé lo storico (la FK degli attempt è
  # `restrict` e `host_id` è NOT NULL: o va giù tutto, o la riga resta).
  describe "DELETE (eliminare una macchina dismessa)" do
    it "elimina host e storico, e torna all'elenco" do
      sign_in(owner)
      host = offline_host(hostname: "mac-dismesso")
      workflow = create(:agent_workflow, organization:)
      attempt = create(:agent_attempt, workflow:, host:)

      delete member_agent_path(host), params: { confirm: "1" }

      expect(response).to redirect_to(member_agents_path)
      expect(Agents::Host.where(id: host.id)).not_to exist
      expect(Agents::Attempt.where(id: attempt.id)).not_to exist
    end

    it "mostra l'azione a chi gestisce, con quanto storico verrà perso" do
      sign_in(owner)
      host = offline_host(hostname: "mac-dismesso")
      create(:agent_attempt, workflow: create(:agent_workflow, organization:), host:)

      get member_agent_path(host)

      expect(response.body).to include('data-test="destroy-host"')
    end

    it "non elimina la macchina che sta ancora lavorando" do
      sign_in(owner)
      host = online_host(hostname: "mac-al-lavoro")
      create(:agent_lease, organization:, host:, expires_at: 1.hour.from_now)

      delete member_agent_path(host), params: { confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host))
      expect(Agents::Host.where(id: host.id)).to exist
    end

    context "senza agents.manage" do
      let(:plain_member) { create(:account) }

      before do
        create(:membership, account: plain_member, organization:, role: :member)
        sign_in(plain_member)
      end

      it "non elimina, e non vede nemmeno l'azione" do
        host = offline_host(hostname: "mac-dismesso")

        get member_agent_path(host)
        expect(response.body).not_to include('data-test="destroy-host"')

        delete member_agent_path(host)
        expect(Agents::Host.where(id: host.id)).to exist
      end
    end
  end
end
