# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Approvals::Decide do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:) }
  let(:visible_projects) { Projects::Project.where(id: project.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }
  let(:review_status) { create(:ticket_status, :in_review, organization:) }

  before { organization.update_column(:cto_id, account.id) }

  def decide(key:, decision:, text: nil)
    described_class.call(account:, organization:, visible_projects:, visible_tickets:,
                         key:, decision:, text:)
  end

  def create_ticket(**attributes)
    create(:ticket, organization:, project:, **attributes)
  end

  # Workflow con un piano pronto in attesa del CTO: è la card "analisi dell'automa" della pila.
  def planned_workflow
    ticket = create_ticket
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 1.hour.ago, triaged_at: 30.minutes.ago,
                                       planned_at: Time.current, ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, workflow:, organization:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Il piano", scenarios: [],
                         definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
    workflow
  end

  describe "card non risolvibile" do
    it "ritorna non trovato per una chiave di famiglia sconosciuta" do
      result = decide(key: "pippo:#{SecureRandom.uuid}", decision: :approve)

      expect(result.err?).to be(true)
      expect(result.error.code).to eq("R404-APPROVAL-001")
    end

    it "ritorna non trovato per un ticket che non vedo" do
      altrove = create(:project, organization: create(:organization))
      ticket = create(:ticket, organization: altrove.organization, project: altrove)

      expect(decide(key: "review:#{ticket.id}", decision: :approve).error.code).to eq("R404-APPROVAL-001")
    end

    it "rifiuta una decisione non prevista per quella famiglia" do
      workflow = planned_workflow

      expect(decide(key: "agent_plan:#{workflow.id}", decision: :reply, text: "ciao").error.code)
        .to eq("R403-APPROVAL-001")
    end
  end

  describe "accettazione" do
    it "approva il piano dell'automa" do
      workflow = planned_workflow

      expect(decide(key: "agent_plan:#{workflow.id}", decision: :approve).ok?).to be(true)
      expect(workflow.reload.approved_at).to be_present
    end

    # CYRA-629 — il via libera alla produzione non si chiede più: la scheda non esiste, quindi non
    # c'è niente da accettare. Il ramo dedicato resta al suo posto e si autodisarma — la guardia
    # sotto lock non può più essere vera, e ogni chiamata esce in conflitto.
    it "il rilascio in produzione non si autorizza più: non c'è nessuna scheda" do
      workflow = create(:agent_workflow, :closer_staging_completed, ticket: create_ticket)

      esito = decide(key: "agent_plan:#{workflow.id}", decision: :approve)

      expect(esito.ok?).to be(false)
      expect(workflow.reload.closer_production_approved_at).to be_nil
    end

    it "scrive la nota come commento sul ticket prima di approvare" do
      workflow = planned_workflow

      decide(key: "agent_plan:#{workflow.id}", decision: :approve, text: "Attenzione ai test di sistema")

      expect(workflow.ticket.comments.pluck(:body)).to include("Attenzione ai test di sistema")
      expect(workflow.reload.approved_at).to be_present
    end

    it "approva la review di un ticket e senza nota non lascia commenti" do
      create(:ticket_status, :done, organization:)
      ticket = create_ticket(status: review_status, reviewer: account)

      expect(decide(key: "review:#{ticket.id}", decision: :approve).ok?).to be(true)
      expect(ticket.reload.status.category).to eq("done")
      expect(ticket.comments).to be_empty
    end
  end

  describe "rifiuto" do
    it "senza motivo non fa nulla" do
      workflow = planned_workflow

      result = decide(key: "agent_plan:#{workflow.id}", decision: :reject)

      expect(result.error.code).to eq("R422-APPROVAL-002")
      expect(workflow.reload.planned_at).to be_present
    end

    it "rimanda il piano al planner con il motivo (nuova versione)" do
      workflow = planned_workflow

      expect(decide(key: "agent_plan:#{workflow.id}", decision: :reject, text: "Manca la migrazione").ok?).to be(true)
      expect(workflow.reload.planned_at).to be_nil
      expect(workflow.plans.order(version: :desc).first.change_request).to eq("Manca la migrazione")
    end

    it "riporta in lavorazione un ticket in review" do
      create(:ticket_status, :in_progress, organization:)
      ticket = create_ticket(status: review_status, reviewer: account)

      expect(decide(key: "review:#{ticket.id}", decision: :reject, text: "Non passa i test").ok?).to be(true)
      expect(ticket.reload.status.category).to eq("in_progress")
    end
  end

  # CYRA-675 — «Rivaluta». Non chiede testo e non è un giudizio: rimanda alla pianificazione, che
  # rileggerà il codice di oggi. Cosa fa al workflow lo prova reassess_spec; qui si prova che la
  # porta unica delle decisioni la instradi, e che non la offra dove non vale.
  describe "rivalutazione" do
    it "rimanda la lavorazione alla pianificazione" do
      workflow = planned_workflow

      result = decide(key: "agent_plan:#{workflow.id}", decision: :reassess)

      expect(result).to be_ok
      expect(workflow.reload).to have_attributes(planned_at: nil, phase: "planning")
    end

    it "il piano già scritto resta in archivio" do
      workflow = planned_workflow

      decide(key: "agent_plan:#{workflow.id}", decision: :reassess)

      expect(workflow.reload.plans).not_to be_empty
    end

    it "su una card che non la offre è vietata" do
      ticket = create_ticket(status: review_status, reviewer: account)

      result = decide(key: "review:#{ticket.id}", decision: :reassess)

      expect(result.err?).to be(true)
      expect(result.error.code).to eq("R403-APPROVAL-001")
    end
  end

  describe "richiesta di precisazioni" do
    it "pubblica la domanda nella discussione e la segna in cronologia" do
      workflow = planned_workflow

      result = decide(key: "agent_plan:#{workflow.id}", decision: :ask, text: "Perché due tabelle e non una?")

      expect(result.ok?).to be(true)
      expect(workflow.ticket.comments.pluck(:body)).to include("Perché due tabelle e non una?")
      event = workflow.ticket.events.find_by(action: described_class::ASK_ACTION)
      expect(event.data["comment_id"]).to eq(result.value.id)
    end

    it "non tocca lo stato del piano" do
      workflow = planned_workflow

      decide(key: "agent_plan:#{workflow.id}", decision: :ask, text: "Una domanda")

      expect(workflow.reload.planned_at).to be_present
      expect(workflow.approved_at).to be_nil
    end

    it "senza testo non pubblica niente" do
      workflow = planned_workflow

      expect(decide(key: "agent_plan:#{workflow.id}", decision: :ask).error.code).to eq("R422-APPROVAL-003")
      expect(workflow.ticket.comments).to be_empty
    end

    # AddComment#capture_clarification_response aggancia come RISPOSTA il primo commento umano su un
    # ticket con una domanda dell'automa aperta: chiederebbe chiudendo una domanda a cui non si è
    # risposto, e rimetterebbe il ticket in coda al triage. Per questo l'azione non è offerta finché
    # quella domanda è viva — si risponde dalla sua card, che è nella stessa pila.
    it "è rifiutata finché l'automa ha una domanda aperta sullo stesso ticket" do
      ticket = create_ticket(status: review_status, reviewer: account)
      workflow = create(:agent_workflow, ticket:, triage_started_at: 1.hour.ago)
      attempt = create(:agent_attempt, workflow:, organization:)
      clarification = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      result = decide(key: "review:#{ticket.id}", decision: :ask, text: "E il rollback?")

      expect(result.error.code).to eq("R403-APPROVAL-001")
      expect(clarification.reload.answered_at).to be_nil
      expect(ticket.comments).to be_empty
    end
  end

  describe "risposta a una domanda dell'automa" do
    it "pubblica la risposta e chiude la domanda" do
      ticket = create_ticket(reviewer: account)
      workflow = create(:agent_workflow, ticket:, triage_started_at: 1.hour.ago)
      attempt = create(:agent_attempt, workflow:, organization:)
      clarification = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      result = decide(key: "clarification:#{clarification.id}", decision: :reply, text: "Produzione")

      expect(result.ok?).to be(true)
      expect(clarification.reload.answered_at).to be_present
    end

    # CYRA-665 — la coda propone la domanda al solo revisore: la card non deve restare una
    # scorciatoia per chi la coda non l'ha mai raggiunto.
    it "non lascia rispondere chi vede il ticket senza esserne revisore" do
      altro = create(:account)
      create(:membership, account: altro, organization:, role: :member)
      ticket = create_ticket(reviewer: altro)
      workflow = create(:agent_workflow, ticket:, triage_started_at: 1.hour.ago)
      attempt = create(:agent_attempt, workflow:, organization:)
      clarification = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      result = decide(key: "clarification:#{clarification.id}", decision: :reply, text: "Produzione")

      expect(result.ok?).to be(false)
      expect(clarification.reload.answered_at).to be_nil
    end
  end

  describe "richieste sui segreti" do
    let(:collega) { create(:account) }

    before { create(:membership, account: collega, organization:, role: :member) }

    it "approva la richiesta di un altro" do
      change_request = create(:secret_change_request, project:, organization:, requested_by: collega)

      expect(decide(key: "secret_change:#{change_request.id}", decision: :approve).ok?).to be(true)
      expect(change_request.reload.status).to eq("applied")
    end

    it "non permette di decidere la propria (4-eyes)" do
      change_request = create(:secret_change_request, project:, organization:, requested_by: account)

      expect(decide(key: "secret_change:#{change_request.id}", decision: :approve).error.code)
        .to eq("R404-APPROVAL-001")
    end
  end
end
