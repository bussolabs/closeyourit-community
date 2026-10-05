# frozen_string_literal: true

require "rails_helper"

# CYRA-593 — la pagina che elenca TUTTE le lavorazioni in volo, comprese quelle che l'agente sta
# ancora facendo e che non chiedono niente a nessuno.
RSpec.describe "Member::Home::Approvals — ciò che va avanti da solo", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org, key: "ALFA", name: "Progetto Alfa") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # CYRA-630 — l'elenco non è più una pagina sua: è il secondo elenco della pagina delle decisioni.
  def in_flight_path(**filtri) = member_home_approvals_path(view: "in_flight", **filtri)

  def ticket_in(target = project, **attributes)
    create(:ticket, organization: org, project: target, **attributes)
  end

  # Una lavorazione che l'agente sta ancora facendo: non chiede niente a nessuno.
  def running_workflow(target = project, host: nil, title: "Lavoro in corso")
    workflow = create(:agent_workflow, ticket: ticket_in(target, title: title),
                                       triage_requested_at: 2.hours.ago, triage_started_at: 1.hour.ago)
    create(:agent_attempt, workflow: workflow, organization: org, phase: "triage", status: :running,
                           started_at: 30.minutes.ago, **(host ? { host: host } : {}))
    workflow
  end

  # Una lavorazione ferma ad aspettare una persona: il piano è pronto e nessuno l'ha approvato.
  def awaiting_workflow(target = project, title: "Piano da approvare")
    create(:agent_workflow, ticket: ticket_in(target, title: title), triage_requested_at: 3.hours.ago,
                            triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
  end

  # CYRA-871 — il rilascio che aspetta la produzione dice fino a quando, e offre «Ferma». Due righe
  # insieme: una query per riga la vedrebbe Prosopite.
  describe "il rilascio che aspetta la produzione" do
    let!(:repository) { create(:github_repository, project:) }

    def in_attesa_della_produzione(verificato_da:)
      ticket = create(:ticket, :agent_workable, organization: org, project:, with_agent_workflow: true)
      pronta_per!(ticket.agent_workflow, "closer_production")
      ticket.agent_workflow.tap { |workflow| workflow.update!(closer_staging_verified_at: verificato_da) }
    end

    it "dice da che ora parte e offre di fermarlo" do
      workflow = in_attesa_della_produzione(verificato_da: 30.minutes.ago).reload
      in_attesa_della_produzione(verificato_da: 3.hours.ago)
      sign_in(owner)

      get in_flight_path

      at = I18n.l(workflow.closer_staging_verified_at + Agents::Workflows::ProductionHold::WINDOW, format: :short)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("member.approvals.in_flight.production_soak", at:)))
      expect(response.body.scan('data-test="approvals-in-flight-production-hold"').size).to eq(2)
    end
  end

  describe "GET index" do
    # Scenario 1 — in coda non compariva: qui compare, con tutto quello che serve a capirla.
    it "mostra anche la lavorazione in corso che non chiede nessuna decisione" do
      workflow = running_workflow(title: "Il salvataggio va in errore")
      sign_in(owner)

      get in_flight_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="approvals-in-flight-row"')
      expect(response.body).to include(workflow.ticket.code)
      expect(response.body).to include("Il salvataggio va in errore")
    end

    # Scenario 2 — è ciò che questa pagina ha in più rispetto a quella del singolo agente.
    it "ogni riga dice a quale progetto appartiene e quale agente la sta facendo" do
      host = create(:agent_host, organization: org, hostname: "dev-laptop")
      running_workflow(project, host: host)
      sign_in(owner)

      get in_flight_path

      expect(response.body).to include('data-test="approvals-in-flight-project"')
      expect(response.body).to include("ALFA")
      expect(response.body).to include('data-test="approvals-in-flight-agent"')
      expect(response.body).to include("dev-laptop")
    end

    it "porta le fasi svolte, l'ultimo esito, il tempo e l'ultima attività" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 4.hours.ago,
                                         triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago)
      create(:agent_attempt, workflow: workflow, organization: org, phase: "triage", status: :approved,
                             started_at: 3.hours.ago, finished_at: 3.hours.ago + 90)
      sign_in(owner)

      get in_flight_path

      # CYRA-608 — la fila delle sigle tecniche non c'è più: diceva la stessa cosa del badge accanto
      # in un'altra lingua. Lo stato lo dice il badge, con la parola del modello.
      expect(response.body).not_to include('data-test="approvals-in-flight-phases"')
      expect(response.body).to include('data-test="approvals-in-flight-state"')
      expect(response.body).to include('data-test="approvals-in-flight-outcome"')
      expect(response.body).to include('data-test="approvals-in-flight-host-time"')
      expect(response.body).to include('data-test="approvals-in-flight-last"')
    end

    # CYRA-630 — il conteggio in testata è UNO: quante vanno avanti da sole. Chi aspetta una persona
    # ha il suo numero accanto, sulla coda delle decisioni, e i due non contano la stessa riga.
    it "conta in testata quante ne vanno avanti da sole, e non ci mette chi aspetta una persona" do
      awaiting_workflow
      running_workflow
      sign_in(owner)

      get in_flight_path

      conteggio = Nokogiri::HTML(response.body).at_css('[data-test="approvals-count-in-flight"]')
      expect(conteggio.text).to include("1")
    end

    # Scenario 4 — chi aspetta una persona non è in questo elenco: sta in quello accanto, dove il
    # pulsante c'è. Qui non c'è niente da premere, per costruzione.
    it "non contiene chi aspetta una persona, e non porta nessun pulsante" do
      in_attesa = awaiting_workflow(title: "Questa aspetta me")
      running_workflow(title: "Questa va avanti da sola")
      sign_in(owner)

      get in_flight_path

      expect(response.body).to include("Questa va avanti da sola")
      expect(response.body).not_to include(in_attesa.ticket.code)
      expect(response.body).not_to include('data-test="approvals-in-flight-decide"')
    end

    # La pagina attraversa tutti i progetti e tutte le macchine: una query per riga qui sarebbe
    # decine di query. Prosopite gira su ogni request spec e alza da sé se ricompare.
    it "regge un elenco di più lavorazioni senza interrogare il database per riga" do
      # Le fixture in blocco creano ticket e tentativi uno per uno (numerazione del ticket,
      # validazione tenant del tentativo): sono query di SETUP, non della pagina.
      allow_n_plus_one do
        altro_progetto = create(:project, organization: org, key: "BETA")
        3.times { running_workflow(project, host: create(:agent_host, organization: org)) }
        2.times { running_workflow(altro_progetto, host: create(:agent_host, organization: org)) }
        # In attesa di una persona: sta nell'altro elenco, e non deve comparire fra le righe contate.
        awaiting_workflow
      end
      sign_in(owner)

      get in_flight_path

      expect(response).to have_http_status(:ok)
      expect(response.body.scan('data-test="approvals-in-flight-row"').size).to eq(5)
    end

    it "dice che non c'è niente in volo quando l'elenco è vuoto" do
      project # CYRA-665 — l'elenco esiste per chi risponde di almeno un progetto
      sign_in(owner)

      get in_flight_path

      expect(response.body).to include('data-test="approvals-in-flight-empty"')
    end

    it "non mostra le lavorazioni dei progetti che chi guarda non può vedere" do
      project
      altra = create(:organization)
      estraneo = create(:ticket, organization: altra, title: "Roba di un'altra")
      create(:agent_workflow, ticket: estraneo, triage_requested_at: 1.hour.ago)
      sign_in(owner)

      get in_flight_path

      expect(response.body).not_to include("Roba di un'altra")
      expect(response.body).to include('data-test="approvals-in-flight-empty"')
    end
  end

  # CYRA-630 — «una porta sola» vale dove una porta c'è. La scheda della lavorazione esiste solo
  # quando c'è qualcosa da decidere: su una lavorazione che l'agente sta facendo non c'è niente, e
  # `Detail` non la risolve. Un link che rimanda all'elenco da cui si è partiti è un pulsante che non
  # fa niente — peggio di nessun pulsante.
  describe "dove porta una riga" do
    it "una lavorazione impiantata porta alla sua scheda, dove si può chiudere" do
      workflow = create(:agent_workflow, ticket: ticket_in(title: "Impiantata"),
                                         triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago,
                                         triaged_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization: org, phase: "planner", status: :review_failed,
                             review: { "summary" => "Il piano non copre il rollback" },
                             review_status: :changes_requested)
      sign_in(owner)

      get in_flight_path

      link = Nokogiri::HTML(response.body).at_css('[data-test="approvals-in-flight-ticket"]')
      expect(link["href"]).to eq(member_home_approvals_item_path(kind: "agent_plan", id: workflow.id,
                                                                 view: "in_flight"))
    end

    # Qui non c'è niente da decidere: si va dove la lavorazione si legge davvero, cioè il ticket.
    it "una lavorazione che l'agente sta facendo porta al suo ticket, non a una scheda che non esiste" do
      workflow = running_workflow(title: "La sta facendo un agente")
      sign_in(owner)

      get in_flight_path

      link = Nokogiri::HTML(response.body).at_css('[data-test="approvals-in-flight-ticket"]')
      expect(link["href"]).to eq(member_ticket_path(workflow.ticket))
    end
  end

  describe "filtri" do
    let(:altro_progetto) { create(:project, organization: org, key: "BETA", name: "Progetto Beta") }

    # Scenario 3 — restano solo le righe che corrispondono e il conteggio segue.
    it "restringe a un progetto" do
      running_workflow(project, title: "Riga di Alfa")
      running_workflow(altro_progetto, title: "Riga di Beta")
      sign_in(owner)

      get in_flight_path(project: "BETA")

      expect(response.body).to include("Riga di Beta")
      expect(response.body).not_to include("Riga di Alfa")
    end

    it "restringe a un agente" do
      host = create(:agent_host, organization: org, hostname: "mac-uno")
      running_workflow(project, host: host, title: "Riga del mac")
      running_workflow(project, title: "Riga di un altro")
      sign_in(owner)

      get in_flight_path(agent_id: host.id)

      expect(response.body).to include("Riga del mac")
      expect(response.body).not_to include("Riga di un altro")
    end

    it "restringe a uno stato, dentro il perimetro" do
      running_workflow(title: "Sta lavorando")
      create(:agent_workflow, ticket: ticket_in(title: "Non è mai partita"), triage_requested_at: nil)
      sign_in(owner)

      get in_flight_path(state: "running")

      expect(response.body).to include("Sta lavorando")
      expect(response.body).not_to include("Non è mai partita")
    end

    # CYRA-630 — «aspetta te» non è uno stato di questo elenco: chiederlo vale come nessun filtro,
    # non apre una finestra sull'altro elenco.
    it "chiedere lo stato dell'altro elenco vale come nessun filtro" do
      in_attesa = awaiting_workflow(title: "Aspetta una persona")
      running_workflow(title: "Sta lavorando")
      sign_in(owner)

      get in_flight_path(state: "waiting")

      expect(response.body).to include("Sta lavorando")
      expect(response.body).not_to include(in_attesa.ticket.code)
    end

    it "mostra i filtri di progetto e di agente quando c'è più di una scelta" do
      host = create(:agent_host, organization: org, hostname: "mac-uno")
      altro_host = create(:agent_host, organization: org, hostname: "mac-due")
      running_workflow(project, host: host)
      running_workflow(altro_progetto, host: altro_host)
      sign_in(owner)

      get in_flight_path

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("select[data-test='approvals-in-flight-filter-project']")).to be_present
      expect(pagina.at_css("select[data-test='approvals-in-flight-filter-agent']")).to be_present
    end

    it "ignora un filtro fuori vocabolario invece di svuotare la pagina" do
      running_workflow(title: "Resta comunque")
      sign_in(owner)

      get in_flight_path(project: "ZZZZ", state: "inventato", agent_id: "non-un-id")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Resta comunque")
    end
  end

  describe "accesso" do
    it "chiede di entrare a chi non ha una sessione" do
      get in_flight_path

      expect(response).to redirect_to(login_path)
    end
  end

  # CYRA-630 — qui si provava che la pagina avesse la sua voce di menu. Non ce l'ha più: quello che
  # la voce diceva lo dice il secondo numero accanto al primo, sulla pagina delle decisioni, ed è da
  # lì che ci si arriva.
  it "non ha più una voce di menu: ci si arriva dalla pagina delle decisioni" do
    running_workflow
    sign_in(owner)

    get in_flight_path
    expect(response.body).not_to include('data-test="member-nav-workflows"')

    get member_home_approvals_path
    expect(response.body).to include('data-test="approvals-in-flight-link"')
  end

  # CYRA-608 — la riga diceva la stessa cosa due volte con due lingue diverse: «triage · piano ·
  # lavorazione» a sinistra e «In coda per la lavorazione» a destra, dove la prima «lavorazione» è un
  # passaggio già fatto e la seconda un'attesa che deve ancora cominciare.
  describe "una parola sola per riga" do
    # La prova va costruita sulla fase VERA della riga, non su un elenco generico: un elenco di nomi
    # che quella riga non avrebbe mostrato comunque resta verde anche se il badge torna al vocabolario
    # interno, e non prova niente.
    it "lo stato è la parola del modello, non il nome interno della fase" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 30.minutes.ago)
      sign_in(owner)

      get in_flight_path

      fase = workflow.reload.phase
      parola_modello = I18n.t("member.tickets.automation.stage.#{Agents::Workflows::PhaseResolver.stage(fase)}")
      nome_interno = I18n.t("member.tickets.automation.phase.#{fase}")

      expect(response.body).to include(parola_modello)
      expect(nome_interno).not_to eq(parola_modello), "fase #{fase}: scegline una in cui i due vocabolari differiscono"
      expect(response.body).not_to include(nome_interno)
    end

    it "l'intestazione della colonna sparita non c'è più" do
      project
      sign_in(owner)

      get in_flight_path

      expect(response.body).not_to include(I18n.t("member.approvals.in_flight.col_phases", default: "Passaggi svolti"))
    end
  end
end
