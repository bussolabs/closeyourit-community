# frozen_string_literal: true

require "rails_helper"

# CYRA-591 — la scheda di UNA lavorazione, su una pagina sua.
#
# PERCHÉ ESISTE: il piano di una lavorazione è un documento da mille o duemila parole (analisi
# tecnica, sette scenari, definizione di fatto, note) e nella coda a tre colonne veniva schiacciato
# in una colonna stretta. Misurato in produzione: 110 lavorazioni, e il dettaglio della prima era già
# troncato con un «Mostra tutto».
#
# E la scheda cambia col PASSO: approvare un piano è leggere un documento, accettare un lavoro è
# guardare delle prove, autorizzare un rilascio è una conferma, sbloccare una lavorazione ferma è
# capire cosa l'ha bloccata. Mostrare sempre le stesse cose costringe a cercare ogni volta.
RSpec.describe "Member::Home::Approvals#show", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ticket_without_workflow(**attributes)
    create(:ticket, organization: org, project:, **attributes)
  end

  # Piano pronto, in attesa che qualcuno lo approvi.
  def planned_workflow(**attributes)
    create(:agent_workflow, ticket: ticket_without_workflow(**attributes),
                            triage_requested_at: 2.days.ago, triaged_at: 1.day.ago, planned_at: Time.current)
  end

  # Lavoro consegnato dall'automa, in attesa che qualcuno lo accetti.
  def delivered_workflow(**attributes)
    create(:agent_workflow, ticket: ticket_without_workflow(**attributes),
                            triage_requested_at: 2.days.ago, triaged_at: 1.day.ago, planned_at: 1.day.ago,
                            approved_at: 1.day.ago, autopilot_started_at: 1.day.ago,
                            autopilot_completed_at: Time.current, candidate_verified_at: Time.current)
  end

  # Lavorazione ferma davvero (CYRA-267): il triage è stato claimato, la revisione l'ha respinto e la
  # coda non lo ripropone più.
  def stalled_workflow(review: nil)
    create(:agent_workflow, ticket: ticket_without_workflow, triage_requested_at: 2.days.ago,
                            triage_started_at: 1.day.ago).tap do |workflow|
      create(:agent_attempt, workflow:, organization: org, phase: "triage", status: :review_failed,
                             review: review.present? ? { "summary" => review } : {},
                             review_status: (:changes_requested if review.present?))
    end
  end

  def show_workflow(workflow)
    get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)
  end

  describe "la pagina esiste ed è sua" do
    it "una lavorazione si apre su una pagina propria, non dentro la coda" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      show_workflow(workflow)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="approval-show"')
      expect(response.body).to include(workflow.ticket.code)
      # La pila della coda NON viene renderizzata qui: è una pagina, non un pannello dentro un'altra.
      expect(response.body).not_to include('data-test="approvals-stack"')
    end

    it "names the project by its name and its key, not the key alone" do
      project.update!(name: "Shop rails")
      workflow = planned_workflow
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include("Shop rails · #{project.key}")
    end

    # Anti-BOLA. La risposta per «di un'altra organizzazione» dev'essere INDISTINGUIBILE da quella
    # per «già decisa da qualcun altro» e da «id inventato»: se le tre differissero, confrontarle
    # direbbe quali lavorazioni esistono altrove. Sono tutte lo stesso rimando alla coda, che spiega
    # genericamente che quella decisione non è più lì.
    it "la lavorazione di un altro risponde come una già decisa: indistinguibili" do
      altrui = create(:agent_workflow, ticket: create(:ticket, organization: create(:organization)),
                                       triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                       planned_at: Time.current)
      sign_in(owner)

      # Si confronta la FORMA della risposta, non l'indirizzo intero: quello porta l'id chiesto, che
      # per forza differisce. È la forma a dover essere identica.
      def forma(location) = [ response.status, URI.parse(location.to_s).path ]

      show_workflow(altrui)
      di_un_altro = forma(response.location)

      mai_esistita = create(:agent_workflow, ticket: ticket_without_workflow, planned_at: Time.current)
      mai_esistita.destroy!
      show_workflow(mai_esistita)

      expect(di_un_altro).to eq([ 302, member_home_approvals_path ])
      expect(forma(response.location)).to eq(di_un_altro)
    end

    it "una chiave inventata è 404" do
      sign_in(owner)

      get member_home_approvals_item_path(kind: "inventato", id: SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
    end
  end

  # La striscia delle cinque fasi dice sempre dove si è: senza, aprendo la scheda da un link non si
  # capisce a che punto della catena si stia decidendo.
  describe "la striscia delle fasi" do
    it "mostra le cinque fasi e segna quella corrente" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include('data-test="approval-phase-strip"')
      expect(response.body).to include('data-test="approval-phase-current"')
    end

    # Su una lavorazione ferma la fase non è «corrente», è respinta: dire «sei qui» dove invece si è
    # inciampato racconta la cosa sbagliata.
    it "su una lavorazione ferma la fase è segnata come respinta, non come corrente" do
      workflow = stalled_workflow(review: "Prove insufficienti")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include('data-test="approval-phase-failed"')
      expect(response.body).not_to include('data-test="approval-phase-current"')
    end

    # CYRA-837 — i sei passaggi portano le STESSE parole della guida e della plancia. Prima la
    # striscia cercava un vocabolario che non esiste più e in produzione uscivano sei
    # `translation_missing`: chi decideva doveva ricostruire da solo a che momento corrispondessero.
    it "chiama i passaggi con le parole della guida, in inglese" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      show_workflow(workflow)

      striscia = Nokogiri::HTML(response.body).at_css("[data-test='approval-phase-strip']")
      nomi = striscia.css("[data-phase]").map { |voce| voce.text.split(" — ").first.strip }
      expect(nomi).to eq([ "To plan", "Plan to approve", "In progress", "To review", "Closing", "Done" ])
      expect(response.body).not_to include("translation_missing")
    end

    it "su una lavorazione ferma il passaggio respinto ha il nome della guida" do
      workflow = stalled_workflow(review: "Prove insufficienti")
      sign_in(owner)

      show_workflow(workflow)

      striscia = Nokogiri::HTML(response.body).at_css("[data-test='approval-phase-strip']")
      respinto = striscia.at_css("[data-test='approval-phase-failed']")
      expect(respinto["data-phase"]).to eq("to_plan")
      expect(respinto.text).to include("To plan")
      expect(response.body).not_to include("translation_missing")
    end
  end

  describe "ogni passo mostra le sue cose e solo le sue decisioni" do
    it "sul piano si legge il documento, e si può approvare, respingere o chiedere" do
      workflow = planned_workflow(title: "Col piano pronto")
      attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot", scenarios: [],
                           technical_analysis: "Analisi lunghissima del piano.")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include('data-test="approvals-detail-plan"')
      expect(response.body).to include("Analisi lunghissima del piano.")
      expect(response.body).to include('data-test="approvals-approve"')
      expect(response.body).to include('data-test="approvals-reject"')
      expect(response.body).to include('data-test="approvals-ask"')
      # CYRA-675 — finché il piano aspetta un sì, si può ancora chiedere se serve.
      expect(response.body).to include('data-test="approvals-reassess"')
    end

    # CYRA-660 — il piano si legge da questa pagina, ma il file si poteva scaricare solo dalla
    # scheda del ticket: chi decide da qui doveva uscirne per averlo.
    it "il piano si può scaricare senza passare dalla scheda del ticket" do
      workflow = planned_workflow(title: "Col piano pronto")
      attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot", scenarios: [],
                           technical_analysis: "Analisi lunghissima del piano.")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include('data-test="approvals-plan-download"')
      expect(response.body).to include(member_ticket_automation_plan_path(workflow.ticket))
    end

    # Sul lavoro consegnato la cosa che si giudica è il resoconto: è quello che si sta accettando.
    it "sul lavoro consegnato si legge il resoconto di ciò che è stato fatto" do
      workflow = delivered_workflow(title: "Consegnato")
      create(:ticket_report, ticket: workflow.ticket, organization: org, body: "Ho riscritto la coda di invio.")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include('data-test="approvals-detail-report"')
      expect(response.body).to include("Ho riscritto la coda di invio.")
    end

    # Sul piano il lavoro non è ancora cominciato: un blocco «consegnato» dichiarerebbe assente un
    # resoconto che non può esistere.
    it "sul piano non compare nessun blocco del consegnato" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).not_to include('data-test="approvals-detail-report"')
    end

    # Su una lavorazione ferma la prima cosa da leggere è cosa l'ha bloccata, non il piano.
    it "su una lavorazione ferma si legge il tentativo respinto e perché" do
      workflow = stalled_workflow(review: "Mancano i file modificati e i test eseguiti")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).to include('data-test="approvals-detail-attempt"')
      expect(response.body).to include("Mancano i file modificati e i test eseguiti")
    end

    # CYRA-675 — sul lavoro già consegnato dalla macchina la domanda non è più «serve?» ma «va
    # bene?»: il codice è scritto, e riaprire la pianificazione butterebbe via del lavoro vero.
    it "sul lavoro consegnato non si può più chiedere se serve" do
      workflow = delivered_workflow(title: "Consegnato")
      sign_in(owner)

      show_workflow(workflow)

      expect(response.body).not_to include('data-test="approvals-reassess"')
    end
  end

  # CYRA-504 chiedeva qui il via libera al rilascio: una card con la sola autorizzazione, niente
  # respingi e niente domanda. CYRA-629 l'ha tolta — era la terza volta che si chiedeva il permesso
  # sullo stesso lavoro, e fra la seconda approvazione e il sito vero non c'è nessuna scelta da fare.
  #
  # Resta da provare che il link diretto non offra una scorciatoia a quella card: non deve mostrare
  # una decisione che non esiste più. Riceve la stessa risposta di una lavorazione già decisa da
  # qualcun altro — la coda, che racconta com'è finita.
  describe "il rilascio in produzione" do
    it "non chiede più niente: il link diretto non produce nessuna card" do
      workflow = create(:agent_workflow, :closer_staging_completed,
                        ticket: ticket_without_workflow(title: "Pronto per la produzione"))
      sign_in(owner)

      show_workflow(workflow)

      expect(workflow.reload.phase).to eq("closer_production_queued")
      expect(response).to redirect_to(member_home_approvals_path(item: "agent_plan:#{workflow.id}"))
    end
  end

  # La scheda rende lo STESSO corpo della coda: se mostrasse meno, la pagina nata per dare più spazio
  # al contenuto ne mostrerebbe meno della colonna stretta che sostituisce. È successo davvero, su
  # due delle sei situazioni, e nessuna spec se ne accorgeva.
  describe "parità col dettaglio della coda" do
    it "su una review si leggono descrizione, analisi tecnica e criteri di accettazione" do
      ticket = create(:ticket, organization: org, project:,
                               status: create(:ticket_status, :in_review, organization: org), reviewer: owner,
                               description: "DESCRIZIONE-SONDA", technical_analysis: "ANALISI-SONDA")
      create(:ticketing_condition, ticket:, text: "CRITERIO-SONDA")
      sign_in(owner)

      get member_home_approvals_item_path(kind: "review", id: ticket.id)

      expect(response.body).to include("DESCRIZIONE-SONDA")
      expect(response.body).to include("ANALISI-SONDA")
      expect(response.body).to include("CRITERIO-SONDA")
    end

    # Approvare una modifica a un segreto senza sapere QUALE variabile, in quale ambiente e chi l'ha
    # chiesta è approvare alla cieca — e il pannello offriva Approva e Rifiuta comunque.
    it "su una modifica ai segreti si legge di cosa si tratta prima di approvarla" do
      environment = create(:environment, organization: org, label: "Produzione")
      request = create(:secret_change_request, organization: org, project:, environment:,
                                               name: "VARIABILE_SONDA", requested_by: create(:account))
      sign_in(owner)

      get member_home_approvals_item_path(kind: "secret_change", id: request.id)

      expect(response.body).to include("VARIABILE_SONDA")
      expect(response.body).to include("Produzione")
    end
  end

  # Una pagina a cui non porta nessun link non esiste per chi la usa. Il percorso ha due passi da
  # quando la coda e' diventata una plancia (CYRA-592): la riga porta alla richiesta aperta, e da li'
  # si apre a tutta pagina. Si provano tutti e due, perche' basta che si spezzi un anello e la scheda
  # torna irraggiungibile senza che nessuna spec se ne accorga.
  describe "ci si arriva" do
    it "la riga della plancia porta alla richiesta aperta" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      get member_home_approvals_path

      expect(response.body).to include('data-test="approvals-board-decide"')
      expect(response.body).to include(CGI.escapeHTML(member_home_approvals_path(item: "agent_plan:#{workflow.id}")))
    end

    it "dalla richiesta aperta si apre la scheda a tutta pagina" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-open-full"')
      expect(response.body).to include(member_home_approvals_item_path(kind: "agent_plan", id: workflow.id))
    end
  end

  # Il prodotto NON monta `rails-i18n`: la locale italiana è scritta a mano, chiave per chiave, e un
  # formato data mancante non degrada — solleva, e la pagina esce come 500. Tutte le spec qui sopra
  # girano nella locale di default (inglese) e quel guasto non lo vedrebbero mai.
  #
  # Questa pagina è piena di tempi: quando è partito un tentativo, quanto è durato, quand'è stato
  # scritto un piano. È esattamente la forma di pagina che quel difetto colpisce.
  describe "in italiano" do
    # Si cambia lingua a chi decide già, invece di inventare un secondo proprietario: la lingua della
    # pagina la sceglie l'account (`Current.account&.effective_locale`), non la richiesta.
    let(:italiano) { owner }

    # `locale` non è una colonna: è una preferenza dentro `preferences` (store_accessor).
    before { owner.update!(locale: "it") }

    it "il piano si apre senza sollevare sui formati data" do
      workflow = planned_workflow(title: "Col piano pronto")
      attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot", scenarios: [],
                           technical_analysis: "Analisi in italiano.")
      sign_in(italiano)

      show_workflow(workflow)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Torna alle approvazioni")
    end

    # La scheda più densa di date: il tentativo porta inizio, durata ed esito.
    it "la lavorazione ferma si apre senza sollevare sui formati data" do
      workflow = stalled_workflow(review: "Prove insufficienti")
      sign_in(italiano)

      show_workflow(workflow)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="approvals-detail-attempt"')
    end

    # CYRA-837 — i passaggi in italiano, con le parole della guida.
    it "chiama i passaggi con le parole della guida, in italiano" do
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(italiano)

      show_workflow(workflow)

      striscia = Nokogiri::HTML(response.body).at_css("[data-test='approval-phase-strip']")
      nomi = striscia.css("[data-phase]").map { |voce| voce.text.split(" — ").first.strip }
      expect(nomi).to eq([ "Da pianificare", "Piano da approvare", "In lavorazione", "Da revisionare",
                           "In chiusura", "Fatto" ])
      expect(response.body).not_to include("translation_missing")
    end

    it "il lavoro consegnato si apre senza sollevare sui formati data" do
      workflow = delivered_workflow(title: "Consegnato")
      create(:ticket_report, ticket: workflow.ticket, organization: org, body: "Fatto.")
      sign_in(italiano)

      show_workflow(workflow)

      expect(response).to have_http_status(:ok)
    end
  end

  # CYRA-389 — qui si respinge un lavoro consegnato, e la motivazione è tutto il valore del gesto: il
  # campo dichiara la misura del posto in cui la motivazione viene salvata (il resoconto), non quella
  # di un messaggio breve.
  describe "quanto si può scrivere respingendo" do
    it "il campo del motivo dichiara il tetto del resoconto" do
      ticket = create(:ticket, organization: org, project:,
                               status: create(:ticket_status, :in_review, organization: org), reviewer: owner)
      create(:ticket_report, ticket:, organization: org, body: "Fatto e verificato.")
      sign_in(owner)

      get member_home_approvals_item_path(kind: "review", id: ticket.id)

      pagina = Nokogiri::HTML(response.body)
      campo = pagina.at_css("[data-test='approvals-reject-reason']")
      expect(campo).to be_present
      contatore = campo.ancestors("[data-controller='char-counter']").first
      expect(contatore).to be_present
      expect(contatore["data-char-counter-max-value"])
        .to eq(Ticketing::Constants::REVIEW_REASON_MAX_CHARS.to_s)
    end
  end

  # La domanda dell'automa ha il verso opposto: chiede lui, l'unica azione è rispondere.
  describe "la domanda dell'automa" do
    it "si può solo rispondere" do
      workflow = planned_workflow(title: "Con una domanda aperta", reviewer: owner)
      clarification = create(:agent_clarification, workflow:, answered_at: nil)
      sign_in(owner)

      get member_home_approvals_item_path(kind: "clarification", id: clarification.id)

      expect(response.body).to include('data-test="approvals-reply-text"')
      expect(response.body).not_to include('data-test="approvals-approve"')
    end

    # CYRA-665 — chi non è il revisore la domanda non ce l'ha in coda: nemmeno per indirizzo. 404 e
    # mai 403, come per ogni card che non compete.
    it "non esiste per chi vede il ticket senza esserne revisore" do
      altro = create(:account)
      create(:membership, account: altro, organization: org, role: :member)
      workflow = planned_workflow(title: "Domanda di un altro", reviewer: altro)
      clarification = create(:agent_clarification, workflow:, answered_at: nil)
      sign_in(owner)

      get member_home_approvals_item_path(kind: "clarification", id: clarification.id)

      # Rimanda alla coda con la chiave, come per ogni card che non risolve: là si spiega che non
      # c'è (o che l'ha decisa qualcun altro), senza dire quale dei due motivi sia.
      expect(response).to redirect_to(member_home_approvals_path(item: "clarification:#{clarification.id}"))
    end
  end
end
