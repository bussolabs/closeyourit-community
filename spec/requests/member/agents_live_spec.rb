# frozen_string_literal: true

require "rails_helper"

# CYRA-823 — la scheda di un agente è due cose diverse messe insieme: quello che la macchina sta
# facendo ADESSO, che cambia da solo, e i lavori che ha già chiuso, che si sfogliano. Finché erano
# un blocco unico, seguire una lavorazione voleva dire ricaricare anche rendimento e storico, e
# girare pagina nello storico ricalcolava anche l'attività e il confronto fra periodi.
# Qui si prova il confine: due frame, ognuno che carica SOLO i suoi dati, con lo stesso gate della
# pagina intera e la stessa oscuratura dei ticket non visibili.
RSpec.describe "Member::Agents — attività e storico separati (CYRA-823)", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def online_host(**attrs)
    create(:agent_host, organization:, last_heartbeat_at: 30.seconds.ago,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
  end

  # Una lavorazione chiusa: è ciò che popola storico e rendimento (stesso helper di agents_spec).
  def concluded(host:, workflow: nil, phase: "triage", status: :approved, seconds: 60, age: 1.hour)
    workflow ||= create(:agent_workflow, organization:)
    started = age.ago
    create(:agent_attempt, organization:, host:, workflow:, phase:, status:,
                           started_at: started, finished_at: started + seconds)
    workflow
  end

  def frame(name) = { "Turbo-Frame" => name }

  # Chi vede gli agenti ma NON i progetti: `agents.view` è org-level, la visibilità dei ticket è
  # per progetto. È il caso su cui si prova che il frame non salti il filtro della pagina.
  def solo_agenti
    account = create(:account)
    create(:membership, organization:, account:)
    create(:account_permission, account:, organization:, permission_key: "agents.view", effect: :allow)
    account
  end

  describe "la pagina intera" do
    before { sign_in(owner) }

    it "dichiara i due frame e l'aggancio agli aggiornamenti in arrivo" do
      host = online_host(hostname: "mac-1")

      get member_agent_path(host)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="host-activity"')
      expect(response.body).to include("turbo-cable-stream-source")
      expect(response.body).to include('data-controller="agent-activity"')

      # CYRA-1032 — the history frame lives on the work tab.
      get member_agent_path(host, tab: "work")
      expect(response.body).to include('id="host-worked"')
    end

    it "renders each tab whole: no gap left for a second request to fill" do
      host = online_host(hostname: "mac-1")
      concluded(host:)

      get member_agent_path(host)
      expect(response.body).to include('data-test="host-activity"', 'data-test="host-performance"')

      get member_agent_path(host, tab: "work")
      expect(response.body).to include('data-test="host-worked-tickets"', 'data-test="worked-row"')
    end
  end

  describe "il frame dell'attività" do
    before { sign_in(owner) }

    it "porta l'attività e i contatori che la descrivono, e nient'altro" do
      ticket = create(:ticket, organization:, title: "Sistemare la navbar")
      host = online_host(hostname: "mac-1",
                         active_runs: [ { "ticket" => ticket.code, "phase" => "verifying" } ])
      concluded(host:)

      get member_agent_path(host), headers: frame("host-activity")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="host-activity"')
      expect(response.body).to include('data-test="host-activity"')
      # I contatori vivono nella stessa risposta dell'elenco: sono la stessa osservazione.
      expect(response.body).to include('data-test="host-running"', 'data-test="host-slots"')
      expect(response.body).to include(ticket.code, "Sistemare la navbar")
      expect(response.body).not_to include('data-test="host-worked-tickets"')
      expect(response.body).not_to include('data-test="host-performance"')
    end

    it "non ricalcola rendimento, confronto fra periodi e storico" do
      host = online_host(hostname: "mac-1")
      concluded(host:)

      expect(::Agents::Hosts::Performance).not_to receive(:call)
      expect(::Agents::Hosts::WorkedTickets).not_to receive(:call)

      get member_agent_path(host), headers: frame("host-activity")

      expect(response).to have_http_status(:ok)
    end

    it "costa meno query della pagina intera" do
      host = online_host(hostname: "mac-1")
      # Le lavorazioni di fixture ripetono per costruzione le query per-record delle factory: non
      # sono query della pagina, e il guard N+1 le conterebbe come tali.
      allow_n_plus_one { 3.times { concluded(host:) } }

      intera = captured_sql { get member_agent_path(host) }
      solo_attivita = captured_sql { get member_agent_path(host), headers: frame("host-activity") }

      expect(solo_attivita.size).to be < intera.size
    end

    # `agents.view` è org-level, i ticket si vedono per progetto: il frame non è una porta di
    # servizio che salta il filtro della pagina.
    it "di un ticket non visibile mostra il codice ma non il titolo" do
      riservato = create(:project, organization:)
      ticket = create(:ticket, organization:, project: riservato, title: "Segreto industriale")
      host = online_host(hostname: "mac-1", active_runs: [ { "ticket" => ticket.code } ])
      sign_in(solo_agenti)

      get member_agent_path(host), headers: frame("host-activity")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ticket.code)
      expect(response.body).not_to include("Segreto industriale")
    end

    # Il caso che il solo segnale non copre: una macchina che muore smette di battere, quindi smette
    # anche di far partire segnali. Lo stato «fermo» lo decide il TEMPO passato dall'ultimo battito,
    # e il riquadro deve dirlo appena qualcuno lo richiede — è ciò che il giro di riconciliazione
    # della pagina va a chiedere.
    it "di una macchina che ha smesso di battere dice che è ferma" do
      ticket = create(:ticket, organization:)
      host = create(:agent_host, organization:, last_heartbeat_at: 30.minutes.ago,
                                 heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1,
                                 active_runs: [ { "ticket" => ticket.code, "phase" => "verifying" } ])

      get member_agent_path(host), headers: frame("host-activity")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="host-run-stalled"')
      expect(response.body).to include(I18n.t("member.agents.status.stale"))
    end

    it "senza il permesso di lettura non si apre" do
      host = online_host(hostname: "mac-1")
      estraneo = create(:account)
      create(:membership, account: estraneo, organization:, role: :member)
      sign_in(estraneo)

      get member_agent_path(host), headers: frame("host-activity")

      expect(response).not_to have_http_status(:ok)
    end

    it "una macchina di un'altra organizzazione resta un 404" do
      altrui = create(:agent_host)

      get member_agent_path(altrui), headers: frame("host-activity")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "il frame dello storico" do
    before { sign_in(owner) }

    it "porta lo storico e nient'altro" do
      host = online_host(hostname: "mac-1")
      concluded(host:)

      get member_agent_path(host), headers: frame("host-worked")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="host-worked"')
      expect(response.body).to include('data-test="host-worked-tickets"')
      expect(response.body).to include('data-test="worked-row"')
      expect(response.body).not_to include('data-test="host-activity"')
      expect(response.body).not_to include('data-test="host-performance"')
    end

    it "sfogliare non ricalcola l'attività né il confronto fra periodi" do
      host = online_host(hostname: "mac-1")
      allow_n_plus_one { 3.times { concluded(host:) } }

      expect(::Agents::Hosts::Performance).not_to receive(:call)

      get member_agent_path(host, page: 2, per: 1), headers: frame("host-worked")

      expect(response).to have_http_status(:ok)
    end

    # Il risparmio del ticket, misurato invece che dichiarato.
    it "costa meno query della pagina intera" do
      host = online_host(hostname: "mac-1")
      # Le lavorazioni di fixture ripetono per costruzione le query per-record delle factory: non
      # sono query della pagina, e il guard N+1 le conterebbe come tali.
      allow_n_plus_one { 3.times { concluded(host:) } }

      intera = captured_sql { get member_agent_path(host) }
      solo_storico = captured_sql { get member_agent_path(host), headers: frame("host-worked") }

      expect(solo_storico.size).to be < intera.size
    end

    it "la pagina richiesta è quella che arriva, coi filtri ancora attivi" do
      host = online_host(hostname: "mac-1")
      vecchio = concluded(host:, phase: "triage", age: 3.hours).ticket
      recente = concluded(host:, phase: "triage", age: 1.hour).ticket

      get member_agent_path(host, per: 1, phase: "triage"), headers: frame("host-worked")
      expect(response.body).to include(recente.code)
      expect(response.body).not_to include(vecchio.code)

      get member_agent_path(host, per: 1, page: 2, phase: "triage"), headers: frame("host-worked")
      expect(response.body).to include(vecchio.code)
      expect(response.body).not_to include(recente.code)
    end

    it "di un ticket non visibile mostra il codice ma non il titolo" do
      workflow = create(:agent_workflow, organization:)
      workflow.ticket.update!(title: "Segreto industriale")
      host = online_host(hostname: "mac-1")
      concluded(host:, workflow:)
      sign_in(solo_agenti)

      get member_agent_path(host), headers: frame("host-worked")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(workflow.ticket.code)
      expect(response.body).not_to include("Segreto industriale")
    end

    it "senza il permesso di lettura non si apre" do
      host = online_host(hostname: "mac-1")
      estraneo = create(:account)
      create(:membership, account: estraneo, organization:, role: :member)
      sign_in(estraneo)

      get member_agent_path(host), headers: frame("host-worked")

      expect(response).not_to have_http_status(:ok)
    end

    it "una macchina di un'altra organizzazione resta un 404" do
      altrui = create(:agent_host)

      get member_agent_path(altrui), headers: frame("host-worked")

      expect(response).to have_http_status(:not_found)
    end
  end

  # Il collegamento che si incolla in chat deve riaprire la stessa vista: periodo, filtri e pagina
  # stanno nell'indirizzo della pagina INTERA, non in quello di un frame.
  describe "il collegamento condiviso" do
    before { sign_in(owner) }

    it "riapre la pagina intera con periodo, filtro e pagina scelti" do
      host = online_host(hostname: "mac-1")
      vecchio = concluded(host:, phase: "triage", age: 3.hours).ticket
      concluded(host:, phase: "triage", age: 1.hour)

      get member_agent_path(host, tab: "work", range: "30d", phase: "triage", per: 1, page: 2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="host-tab-work"', 'data-test="host-worked-tickets"')
      expect(response.body).to include(vecchio.code)
    end
  end
end
