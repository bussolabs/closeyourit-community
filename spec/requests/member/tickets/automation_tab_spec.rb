# frozen_string_literal: true

require "rails_helper"

# CYRA-219 — la tab Automazione. Tutto ciò che mostra è già in tabella e non era reso da nessuna parte:
# result e review di OGNI tentativo, compresi quelli bocciati. Le domande, che prima erano in sola
# lettura, qui si rispondono.
RSpec.describe "Member ticket automation tab", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) { create(:account) }
  let(:host) { create(:agent_host, organization:, hostname: "minion-1.local") }

  before do
    create(:membership, :owner, organization:, account: cto)
    create(:project_membership, project:, account: cto)
    organization.update!(cto:)
    post login_path, params: { email: cto.email, password: "Secret123!" }
  end

  describe "i passi della lavorazione" do
    before do
      workflow.update!(triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "triage", status: :approved,
                             started_at: 3.minutes.ago, finished_at: 2.minutes.ago,
                             result: { "category" => "backend", "risk" => "low",
                                       "reasons" => [ "Tocca solo un service" ] },
                             review: { "status" => "accepted", "summary" => "Schema conforme." })
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :review_failed,
                             started_at: 1.minute.ago, finished_at: 30.seconds.ago,
                             result: { "technical_analysis" => "Allineare il canale dei log" },
                             review: { "status" => "changes_requested", "summary" => "Mancano evidenze." })
    end

    it "mostra ogni tentativo con la macchina, le considerazioni e il verdetto della revisione" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("minion-1.local")
      expect(response.body).to include("Tocca solo un service")
      expect(response.body).to include("Schema conforme.")
      # Il tentativo BOCCIATO è il punto: prima spariva, ed è quello che spiega perché non si avanza.
      expect(response.body).to include("Allineare il canale dei log")
      expect(response.body).to include("Mancano evidenze.")
    end

    # CYRA-282 — un guasto tecnico riportato dalla macchina si legge sulla scheda del ticket, col motivo.
    it "mostra il motivo di un tentativo fallito" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "autopilot", status: :failed,
                             started_at: 20.seconds.ago, finished_at: 10.seconds.ago,
                             failure_reason: "Processo terminato dal kernel OOM killer.",
                             result: {}, review: {})

      get member_ticket_path(ticket, tab: "automation")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.tickets.automation.steps.outcome.failed"))
      expect(response.body).to include("Processo terminato dal kernel OOM killer.")
    end

    # CYRA-802 — i rilievi del revisore erano l'unico pezzo della scheda senza una prova sua, e sono
    # quelli che dicono COSA correggere: il verdetto da solo dice soltanto che non si passa.
    it "mostra i rilievi della revisione, col dettaglio quando c'è" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "autopilot", status: :review_failed,
                             started_at: 20.seconds.ago, finished_at: 10.seconds.ago, result: {},
                             review: { "status" => "changes_requested", "summary" => "Da rivedere.",
                                       "findings" => [
                                         { "severity" => "high", "aspect" => "test",
                                           "title" => "Manca la prova", "detail" => "Il ramo nuovo non è coperto" },
                                         { "severity" => "low", "aspect" => "stile", "title" => "Nome poco chiaro" }
                                       ] })

      get member_ticket_path(ticket, tab: "automation")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Manca la prova", "Il ramo nuovo non è coperto", "Nome poco chiaro")
    end

    it "la tab dettaglio non porta con sé i passi (restano nella propria scheda)" do
      get member_ticket_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Mancano evidenze.")
    end

    # Un tentativo interrotto non ha consegnato: mostrargli i contatori a zero lo farebbe leggere come
    # "ha prodotto un piano vuoto" invece che "non è mai arrivato a produrne uno".
    it "un tentativo interrotto non mostra contatori a zero" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :stale,
                             started_at: 20.seconds.ago, finished_at: 10.seconds.ago, result: {}, review: {})

      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include(I18n.t("member.tickets.automation.steps.outcome.interrupted"))
      expect(response.body).not_to match(/definizione di fatto\s*<span[^>]*>0</)
    end

    # Dal passo alla scheda dell'host: senza il collegamento, per sapere com'è messa la macchina che ha
    # eseguito il tentativo (online, quanto lavora, come le va) bisogna ripescarla a mano nell'elenco.
    it "il nome della macchina porta alla sua scheda" do
      get member_ticket_path(ticket, tab: "automation")

      link = Nokogiri::HTML(response.body).at_css("[data-test='automation-step-host']")
      expect(link.name).to eq("a")
      expect(link[:href]).to eq(member_agent_path(host))
      expect(link.text).to eq("minion-1.local")
    end

    # `agents.view` è ORG-level, la tab la vede chi vede il PROGETTO: senza quel permesso il nome resta
    # testo, invece di offrire un link che porta a un accesso negato.
    it "chi non può vedere gli agenti legge il nome della macchina senza link" do
      member = create(:account)
      create(:membership, organization:, account: member, role: :member)
      create(:project_membership, project:, account: member)
      post login_path, params: { email: member.email, password: "Secret123!" }

      get member_ticket_path(ticket, tab: "automation")

      label = Nokogiri::HTML(response.body).at_css("[data-test='automation-step-host']")
      expect(label.name).to eq("span")
      expect(label.text).to eq("minion-1.local")
      expect(response.body).not_to include(member_agent_path(host))
    end
  end

  # CYRA-281 — su una lavorazione lunga i passi aperti sono decine di blocchi da scorrere prima di
  # arrivare al piano. Chiusi, la riga di intestazione basta a orientarsi; il testo resta lì per chi lo
  # cerca. Restano nel DOM anche da chiusi: è il browser a nasconderli, quindi la pagina si può ancora
  # cercare con Cmd+F e nessuna asserzione sui contenuti cambia.
  describe "i passi si aprono e si chiudono" do
    def steps(body) = Nokogiri::HTML(body).css("[data-test='automation-step']")

    before { workflow.update!(triage_started_at: 9.minutes.ago, triaged_at: 8.minutes.ago) }

    def attempt!(status, **overrides)
      create(:agent_attempt, organization:, workflow:, host:, status:,
             started_at: 5.minutes.ago, finished_at: 4.minutes.ago,
             result: { "technical_analysis" => "Allineare il canale dei log" },
             review: { "status" => "accepted", "summary" => "Schema conforme." }, **overrides)
    end

    it "un passo concluso è chiuso" do
      attempt!(:approved, phase: "planner")

      get member_ticket_path(ticket, tab: "automation")

      details = steps(response.body).first.at_css("details")
      expect(details).to be_present
      expect(details.attributes).not_to have_key("open")
      # Chiuso non vuol dire assente: il testo è nella pagina, solo ripiegato.
      expect(response.body).to include("Allineare il canale dei log")
    end

    it "il passo ancora in corso è aperto senza doverci cliccare" do
      attempt!(:running, phase: "planner", finished_at: nil)

      get member_ticket_path(ticket, tab: "automation")

      expect(steps(response.body).first.at_css("details").attributes).to have_key("open")
    end

    # Spiega perché il lavoro non avanza: è la prima cosa che si va a leggere, e chiuderla costringerebbe
    # a cercarla in fondo a una pila di tentativi riusciti.
    it "l'ultimo passo bocciato è aperto, i bocciati precedenti no" do
      attempt!(:review_failed, phase: "triage", started_at: 7.minutes.ago, finished_at: 6.minutes.ago)
      attempt!(:review_failed, phase: "planner", started_at: 3.minutes.ago, finished_at: 2.minutes.ago)

      get member_ticket_path(ticket, tab: "automation")

      primo, ultimo = steps(response.body).map { |step| step.at_css("details") }
      expect(primo.attributes).not_to have_key("open")
      expect(ultimo.attributes).to have_key("open")
    end

    # CYRA-384 — un tentativo interrotto non ha consegnato niente, ma il suo esito una spiegazione ce
    # l'ha: aprendolo si legge la differenza fra «interrotto» e «fallito», che decide se c'è qualcosa
    # da sistemare o solo da riprovare. Prima non apriva nulla e la sigla restava senza spiegazione.
    it "un passo senza niente da leggere apre almeno la spiegazione del suo esito" do
      attempt!(:stale, phase: "planner", result: {}, review: {})

      get member_ticket_path(ticket, tab: "automation")

      step = steps(response.body).first
      expect(step.text).to include(I18n.t("member.tickets.automation.steps.outcome.interrupted"))
      expect(step.at_css("[data-test='automation-glossary']").text)
        .to include(I18n.t("member.tickets.automation.steps.outcome_hint.interrupted"))
    end
  end

  describe "una lavorazione ferma" do
    before do
      workflow.update!(triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago,
                       blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit",
                       blocked_reason: "review_limit: planner rejected 2 times")
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :review_failed)
    end

    it "dice che è ferma e offre la via d'uscita" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include(I18n.t("member.tickets.automation.blocked.title"))
      expect(response.body).to include(member_ticket_automation_unblock_path(ticket))
    end

    # CYRA-598 — il banner è la prima cosa che si legge sulla scheda, e con un blocco dichiarato
    # dalla macchina la frase del tetto sarebbe falsa due volte: nomina la revisione, che non
    # c'entra, e mostra un conteggio che è ZERO, perché una consegna che dichiara un blocco è valida
    # e si chiude approved. Sarebbe uscito «La revisione ha respinto Pianificazione 0 volte di fila».
    it "quando a fermarla è stata la macchina il banner riporta il suo motivo, non la revisione" do
      workflow.update!(blocked_kind: "agent_blocked", blocked_phase: "triage",
                       blocked_reason: "agent_blocked: Il ticket è finito nella coda del prodotto sbagliato.")

      get member_ticket_path(ticket, tab: "automation")

      # La frase INTERA del banner, non solo il motivo: il motivo compare anche nella riga di sintesi
      # in testa alla scheda, quindi cercarlo e basta lascerebbe passare un banner rimasto com'era.
      atteso = I18n.t("member.tickets.automation.blocked.body_agent",
                      phase: I18n.t("member.tickets.automation.execution_phase.triage"),
                      reason: "Il ticket è finito nella coda del prodotto sbagliato.")
      expect(response.body).to include(CGI.escapeHTML(atteso))
      expect(response.body).not_to include("agent_blocked:")
      # E la frase del tetto non deve comparire da nessuna parte: nominerebbe la revisione e uno zero.
      falsa = I18n.t("member.tickets.automation.blocked.body",
                     phase: I18n.t("member.tickets.automation.execution_phase.triage"), count: 0)
      expect(response.body).not_to include(CGI.escapeHTML(falsa))
    end

    it "e la frase del tetto resta quella di prima quando a fermarla è stato il tetto" do
      get member_ticket_path(ticket, tab: "automation")

      atteso = I18n.t("member.tickets.automation.blocked.body",
                      phase: I18n.t("member.tickets.automation.execution_phase.planner"), count: 1)
      expect(response.body).to include(CGI.escapeHTML(atteso))
    end

    # CYRA-296: chi decide e chi gestisce il ticket sono la stessa persona in questo fixture (il CTO è
    # owner) — il form di annullamento del banner è l'UNICO, non se ne aggiunge un secondo fuori.
    it "mostra un solo form di annullamento quando la stessa persona decide e gestisce" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response.body.scan(member_ticket_automation_cancellation_path(ticket)).size).to eq(1)
    end

    # Annullare è terminale e non azzera il blocco (resta come storia). Se il banner guardasse solo
    # blocked_at, una lavorazione chiusa continuerebbe a chiedere una decisione e a offrire "Riprova" —
    # che su un workflow annullato rifiuta sempre.
    it "su una lavorazione annullata sparisce: non c'è più niente da decidere" do
      workflow.update!(cancelled_at: Time.current, cancellation_reason: "Non serve più")

      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).not_to include(I18n.t("member.tickets.automation.blocked.title"))
      expect(response.body).not_to include(member_ticket_automation_unblock_path(ticket))
    end

    # Chi vede il ticket ma non è né il CTO effettivo né chi lo gestisce trova comunque il riquadro (sa
    # perché la lavorazione sembra ferma) ma nessun pulsante: solo il nome di chi può decidere.
    it "chi non decide e non gestisce vede il riquadro ma non il pulsante" do
      other = create(:account)
      create(:membership, :admin, organization:, account: other)
      create(:project_membership, project:, account: other)
      post login_path, params: { email: other.email, password: "Secret123!" }

      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include(I18n.t("member.tickets.automation.blocked.title"))
      expect(response.body).not_to include(member_ticket_automation_unblock_path(ticket))
      # Sul testo reso: il nome del CTO può contenere un apostrofo, che nell'HTML è `&#39;`.
      expect(Nokogiri::HTML(response.body).text).to include(I18n.t("member.tickets.automation.blocked.waiting_on_cto", name: cto.name))
    end
  end

  describe "una fase bocciata una sola volta, ancora riclamabile" do
    before do
      workflow.update!(triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :review_failed)
    end

    # CYRA-296: il tetto non è ancora esaurito (blocked_at è nil), quindi Unblock sarebbe un no-op — la
    # lavorazione riprova già da sola. Il riquadro spiega quale fase sta riprovando, senza offrire un
    # pulsante che non farebbe nulla.
    it "mostra il riquadro senza il pulsante Riprova, con la fase scritta in italiano" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include(I18n.t("member.tickets.automation.blocked.retrying_title"))
      expect(response.body).to include(I18n.t("member.tickets.automation.execution_phase.planner"))
      expect(response.body).not_to include(member_ticket_automation_unblock_path(ticket))
    end
  end

  describe "le domande di chiarimento" do
    let(:attempt) { create(:agent_attempt, organization:, workflow:, host:, phase: "triage") }
    let!(:clarification) do
      create(:agent_clarification, workflow:, attempt:,
                                    questions: [ "Chi deve vedere il risultato?", "Serve il backfill?" ])
    end

    before { workflow.update!(triage_started_at: 5.minutes.ago, triage_requested_at: nil) }

    # CYRA-782 — le domande non si rispondono più da qui: vivono nella scheda Domande insieme a
    # quelle poste da una persona. Resta il rimando, così chi arriva dall'automazione sa dove andare.
    it "rimanda alla scheda Domande invece di offrire i campi di risposta" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include(I18n.t("member.tickets.questions.from_automation"))
      expect(response.body).to include(member_ticket_path(ticket, tab: "questions"))
    end

    # Stesso fatto di sempre: dopo la cancellazione del commento di risposta, un commento qualsiasi
    # non deve riagganciare un chiarimento già chiuso e rimettere il ticket in coda.
    it "un commento qualsiasi non riapre un chiarimento già risposto" do
      comment = ticket.comments.create!(author: cto, body: "Una risposta")
      clarification.update!(response_comment: comment, response_snapshot: comment.body,
                            answered_at: Time.current)
      comment.destroy!
      workflow.update!(triage_requested_at: nil, triage_started_at: 5.minutes.ago)

      Ticketing::AddComment.call(ticket:, author: cto, params: { body: "Un commento normale" })

      expect(workflow.reload.triage_requested_at).to be_nil
      expect(clarification.reload.response_snapshot).to eq("Una risposta")
    end
  end

  # CYRA-410 — su un ticket appena creato la scheda si contraddiceva da sola: il badge diceva «In coda
  # per la valutazione» e due righe sotto si leggeva «La lavorazione non è mai partita», che suona come
  # un guasto invece che come un'attesa normale. E offriva di annullare qualcosa non ancora cominciato.
  describe "la lavorazione ancora in coda" do
    def queued_text(body) = Nokogiri::HTML(body).at_css("[data-test='automation-steps-queued']")&.text.to_s

    # CYRA-608 — la frase NON ripete più la parola dello stato: la dice già il badge due righe sopra,
    # e con le parole nuove ripeterla la contraddirebbe — «In lavorazione» accanto a «finché non parte
    # non c'è niente da leggere». Resta chiuso il difetto di CYRA-410: non si legge «non è mai
    # partita», che suona come un guasto invece che come un'attesa normale.
    it "descrive l'attesa senza ripetere la parola che il badge ha già detto" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response).to have_http_status(:ok)
      pagina = Nokogiri::HTML(response.body)
      parola = I18n.t("member.tickets.automation.stage.to_plan")

      expect(pagina.at_css("[data-test='automation-summary']").text).to include(parola)
      expect(queued_text(response.body)).not_to include(parola)
      expect(queued_text(response.body)).to include(I18n.t("member.tickets.automation.steps.queued"))
      expect(pagina.text).not_to include(I18n.t("member.tickets.automation.steps.empty"))
    end

    it "dice da quando è in attesa e quanto ci vuole di solito" do
      workflow.update!(triage_requested_at: 3.minutes.ago)

      get member_ticket_path(ticket, tab: "automation")

      testo = queued_text(response.body)
      expect(testo).to include(I18n.l(workflow.reload.triage_requested_at, format: :short))
      expect(testo).to include(I18n.t("member.tickets.automation.steps.queued"))
    end

    # In secondo piano: sul rosso pieno del `danger_outline` l'annullamento pesava quanto l'attesa, su
    # una lavorazione che non ha ancora fatto niente.
    it "l'annullamento resta in secondo piano e dichiara cosa comporta" do
      get member_ticket_path(ticket, tab: "automation")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='automation-cancel']")[:class]).not_to include("text-red-600")
      expect(pagina.at_css("[data-test='automation-cancel-effect']").text)
        .to include(I18n.t("member.tickets.automation.cancel_effect"))
    end

    # Una lavorazione che non è in coda per davvero (nessuna richiesta di valutazione) non deve
    # promettere un avvio che non arriverà: lì il testo neutro resta quello giusto.
    it "una lavorazione mai richiesta continua a dire che non è partita" do
      workflow.update!(triage_requested_at: nil)

      get member_ticket_path(ticket, tab: "automation")

      expect(Nokogiri::HTML(response.body).text).to include(I18n.t("member.tickets.automation.steps.empty"))
      expect(queued_text(response.body)).to be_empty
    end
  end

  describe "il gate sul piano" do
    let(:attempt) { create(:agent_attempt, organization:, workflow:) }

    before do
      workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current, ticket_snapshot_digest: "snapshot")
      Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Il piano", scenarios: [],
                           definition_of_done: [ "Spec verdi" ], notes: [], ticket_snapshot_digest: "snapshot")
    end

    it "mostra i pulsanti al CTO effettivo" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include("Il piano")
      expect(response.body).to include(member_ticket_automation_approval_path(ticket))
    end

    # Vedere la lavorazione è di chiunque veda il ticket; deciderne il piano no. Chi non è il CTO
    # effettivo legge tutto e non trova nessun pulsante — non un pulsante che poi rifiuta.
    it "li nasconde a chi non è il CTO effettivo" do
      other = create(:account)
      create(:membership, :admin, organization:, account: other)
      create(:project_membership, project:, account: other)
      post login_path, params: { email: other.email, password: "Secret123!" }

      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include("Il piano")
      expect(response.body).not_to include(member_ticket_automation_approval_path(ticket))
    end
  end

  # CYRA-384 — la scheda apriva su decine di tentativi quasi identici e un testo lungo: chi doveva
  # decidere non trovava mai la riga che dice cosa è successo, perché il lavoro si è fermato e cosa
  # serve da lui. Le tre righe stanno in cima, prima di tutto il resto.
  describe "la sintesi in tre righe" do
    def pagina = Nokogiri::HTML(response.body)

    it "apre con cosa ha fatto, perché si è fermata e cosa serve" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :approved,
                             started_at: 90.minutes.ago, finished_at: 1.hour.ago)

      get member_ticket_path(ticket, tab: "automation")

      sintesi = pagina.at_css("[data-test='automation-summary']")
      expect(sintesi).to be_present
      expect(sintesi.at_css("[data-test='automation-summary-done']").text)
        .to include(I18n.t("member.tickets.automation.execution_phase.planner"))
      expect(sintesi.at_css("[data-test='automation-summary-stopped']").text)
        .to include(I18n.t("member.tickets.automation.summary.stopped.awaiting_approval"))
      expect(sintesi.at_css("[data-test='automation-summary-needs']").text)
        .to include(I18n.t("member.tickets.automation.summary.needs.approve_plan"))
    end

    # La sintesi viene PRIMA dei passi: è l'inversione che il ticket chiede — oggi per arrivare alla
    # riga che conta bisogna scorrere il registro.
    it "sta sopra il registro dei passi" do
      workflow.update!(triage_started_at: 10.minutes.ago)

      get member_ticket_path(ticket, tab: "automation")

      corpo = response.body
      expect(corpo.index("automation-summary")).to be < corpo.index("automation-steps")
    end

    # La decisione sul piano si prende in cima, nella sintesi, non in fondo alla scheda del piano:
    # è l'azione che il ticket chiede di mettere in evidenza.
    it "porta in evidenza i pulsanti con cui si decide sul piano" do
      attempt = create(:agent_attempt, organization:, workflow:)
      workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current, ticket_snapshot_digest: "snapshot")
      Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Il piano", scenarios: [],
                           definition_of_done: [ "Spec verdi" ], notes: [], ticket_snapshot_digest: "snapshot")

      get member_ticket_path(ticket, tab: "automation")

      decisione = pagina.at_css("[data-test='automation-summary'] [data-test='automation-approve']")
      expect(decisione).to be_present
      # Un solo posto dove si decide: i pulsanti non restano anche in fondo al piano.
      expect(pagina.css("[data-test='automation-approve']").size).to eq(1)
    end

    it "una lavorazione mai partita non finge una sintesi" do
      workflow.update!(triage_requested_at: nil)

      get member_ticket_path(ticket, tab: "automation")

      expect(pagina.at_css("[data-test='automation-summary-done']").text)
        .to include(I18n.t("member.tickets.automation.summary.done.none"))
    end
  end

  # CYRA-384 — «19 tentativi interrotti fra 02:58 e 08:55»: in fila coprivano tutto il resto.
  describe "i tentativi ripetuti raccolti in una riga sola" do
    before do
      workflow.update!(triage_started_at: 5.hours.ago)
      # Fixture in blocco: la validazione tenant di ogni tentativo interroga la membership, e quattro
      # create di fila non sono l'N+1 di una richiesta di produzione.
      allow_n_plus_one do
        4.times do |index|
          create(:agent_attempt, organization:, workflow:, host:, phase: "triage", status: :stale,
                                 started_at: (300 - (index * 10)).minutes.ago,
                                 finished_at: (295 - (index * 10)).minutes.ago, result: {}, review: {})
        end
      end
    end

    it "li raccoglie in una riga che dice quanti sono e in quale arco di tempo" do
      get member_ticket_path(ticket, tab: "automation")

      gruppo = Nokogiri::HTML(response.body).at_css("[data-test='automation-step-group']")
      expect(gruppo).to be_present
      expect(gruppo.text).to include(I18n.t("member.tickets.automation.steps.count", count: 4))
      expect(gruppo.text).to include(I18n.t("member.tickets.automation.steps.outcome.interrupted"))
    end

    # Raccolti non vuol dire persi: il dettaglio resta nella pagina, dentro la riga che si apre.
    it "il dettaglio dei singoli tentativi resta apribile" do
      get member_ticket_path(ticket, tab: "automation")

      gruppo = Nokogiri::HTML(response.body).at_css("[data-test='automation-step-group']")
      expect(gruppo.css("[data-test='automation-step']").size).to eq(4)
      expect(gruppo.name).to eq("details")
      expect(gruppo[:open]).to be_nil
    end

    it "un tentativo con un esito diverso resta una riga per conto suo" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :approved,
                             started_at: 10.minutes.ago, finished_at: 9.minutes.ago,
                             result: { "technical_analysis" => "Il piano scritto" })

      get member_ticket_path(ticket, tab: "automation")

      pagina = Nokogiri::HTML(response.body)
      fuori_dal_gruppo = pagina.css("[data-test='automation-step']").reject do |passo|
        passo.ancestors("[data-test='automation-step-group']").any?
      end
      expect(fuori_dal_gruppo.size).to eq(1)
    end
  end

  # CYRA-384 — «ogni sigla di stato è scritta in italiano e accompagnata da una frase che la spiega».
  describe "le sigle di stato spiegate" do
    it "il passo spiega il suo esito e le sigle che mostra" do
      workflow.update!(triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "triage", status: :approved,
                             started_at: 3.minutes.ago, finished_at: 2.minutes.ago,
                             result: { "state" => "workable", "reasons" => [ "Tocca solo un service" ] },
                             review: { "status" => "accepted", "summary" => "Schema conforme." })

      get member_ticket_path(ticket, tab: "automation")

      glossario = Nokogiri::HTML(response.body).at_css("[data-test='automation-glossary']").text
      expect(glossario).to include(I18n.t("member.tickets.automation.steps.state_hint.workable"))
      expect(glossario).to include(I18n.t("member.tickets.automation.steps.outcome_hint.approved"))
    end

    it "la fase corrente della lavorazione porta la frase che la spiega" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      get member_ticket_path(ticket, tab: "automation")

      expect(Nokogiri::HTML(response.body).at_css("[data-test='automation-phase-hint']").text)
        .to include(I18n.t("member.tickets.automation.phase_hint.awaiting_approval"))
    end
  end
end
