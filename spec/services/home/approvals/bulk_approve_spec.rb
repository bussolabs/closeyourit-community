# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Approvals::BulkApprove do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:) }
  let(:visible_projects) { Projects::Project.where(id: project.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }
  let(:review_status) { create(:ticket_status, :in_review, organization:) }

  before { organization.update_column(:cto_id, account.id) }

  def bulk(keys, as: account)
    described_class.call(account: as, organization:, visible_projects:, visible_tickets:, keys:)
  end

  def create_ticket(**attributes)
    create(:ticket, organization:, project:, **attributes)
  end

  # Workflow con un piano pronto in attesa del CTO: la card "analisi dell'automa" della pila.
  def planned_workflow
    ticket = create_ticket
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 1.hour.ago, triaged_at: 30.minutes.ago,
                                       planned_at: Time.current, ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, workflow:, organization:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Il piano", scenarios: [],
                         definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
    workflow
  end

  def review_ticket
    create(:ticket_status, :done, organization:)
    create_ticket(status: review_status, reviewer: account)
  end

  describe "accettazione di più card" do
    it "accetta insieme famiglie diverse e conta le accettate" do
      collega = create(:account)
      create(:membership, account: collega, organization:, role: :member)
      workflow = planned_workflow
      ticket = review_ticket
      change_request = create(:secret_change_request, project:, organization:, requested_by: collega)

      result = bulk([ "agent_plan:#{workflow.id}", "review:#{ticket.id}", "secret_change:#{change_request.id}" ])

      expect(result.ok?).to be(true)
      expect(result.value.approved).to eq(3)
      expect(result.value.skipped).to be_zero
      expect(workflow.reload.approved_at).to be_present
      expect(ticket.reload.status.category).to eq("done")
      expect(change_request.reload.status).to eq("applied")
    end

    it "non lascia commenti: in blocco non si scrive nessuna nota" do
      workflow = planned_workflow

      bulk([ "agent_plan:#{workflow.id}" ])

      expect(workflow.ticket.comments).to be_empty
    end

    it "conta una volta sola la stessa chiave ripetuta" do
      workflow = planned_workflow

      result = bulk([ "agent_plan:#{workflow.id}", "agent_plan:#{workflow.id}" ])

      expect(result.value.approved).to eq(1)
    end
  end

  describe "card che non entrano nel blocco" do
    it "salta la domanda di un automa: si può solo rispondere" do
      ticket = create_ticket
      workflow = create(:agent_workflow, ticket:, triage_started_at: 1.hour.ago)
      attempt = create(:agent_attempt, workflow:, organization:)
      clarification = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      result = bulk([ "clarification:#{clarification.id}" ])

      expect(result.value.approved).to be_zero
      expect(result.value.skipped).to eq(1)
      expect(clarification.reload.answered_at).to be_nil
    end

    # Su una lavorazione ferma «accetta» significa «sblocca e riprova»: la card OFFRE :approve, ma è
    # un altro gesto e non si fa alla cieca dentro una selezione.
    it "salta una lavorazione ferma anche se la sua card offre l'accettazione" do
      ticket = create_ticket
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                         triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization:, status: :review_failed)
      workflow.update!(blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit", blocked_reason: "tetto tentativi")

      result = bulk([ "agent_plan:#{workflow.id}" ])

      expect(result.value.skipped).to eq(1)
      expect(workflow.reload.blocked_at).to be_present
    end

    # CYRA-504 — mandare in produzione è l'unico passo irreversibile della catena: la card offre
    # :approve, ma dentro una selezione fatta di corsa non ci entra.
    it "salta il via libera alla produzione, che si dà una card per volta" do
      workflow = create(:agent_workflow, :closer_staging_completed, ticket: create_ticket)

      result = bulk([ "agent_plan:#{workflow.id}" ])

      expect(result.value.skipped).to eq(1)
      expect(workflow.reload.closer_production_approved_at).to be_nil
    end

    it "salta la review di chi non può gestire il ticket" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      ticket = review_ticket
      ticket.update!(reviewer: member)

      result = bulk([ "review:#{ticket.id}" ], as: member)

      expect(result.value.skipped).to eq(1)
      expect(ticket.reload.status_id).to eq(review_status.id)
    end

    # Anti-BOLA: la card che non mi compete non esiste — viene scartata, non produce un 403.
    it "scarta una chiave fuori dagli scope visibili e lascia il record intatto" do
      altrove = create(:project, organization: create(:organization))
      altrui_status = create(:ticket_status, :in_review, organization: altrove.organization)
      ticket = create(:ticket, organization: altrove.organization, project: altrove, status: altrui_status)

      result = bulk([ "review:#{ticket.id}" ])

      expect(result.value.skipped).to eq(1)
      expect(ticket.reload.status_id).to eq(altrui_status.id)
    end

    it "scarta una chiave di famiglia sconosciuta" do
      expect(bulk([ "pippo:#{SecureRandom.uuid}" ]).value.skipped).to eq(1)
    end
  end

  describe "quando una card fallisce" do
    # Best-effort, mai una transazione unica: i service di dominio notificano e broadcastano
    # assumendo di aver committato, e una card andata male non deve annullare quelle riuscite.
    it "le altre restano accettate e il fallimento è riportato" do
      buona = planned_workflow
      # Nessuno status "done" in organizzazione → l'approvazione della review non ha dove atterrare.
      rotta = create_ticket(status: review_status, reviewer: account)

      result = bulk([ "agent_plan:#{buona.id}", "review:#{rotta.id}" ])

      expect(result.value.approved).to eq(1)
      expect(result.value.failed).to eq(1)
      expect(result.value.failures.first.key).to eq("review:#{rotta.id}")
      expect(buona.reload.approved_at).to be_present
      expect(rotta.reload.status_id).to eq(review_status.id)
    end

    # CYRA-289: fallire NON è solo tornare un Result.err. Un service di dominio può sollevare — è
    # successo in produzione con il lock del database dei broadcast — e prima l'eccezione propagava
    # fino al controller: 500, mentre le card già accettate ERANO passate. Chi guardava la pagina
    # d'errore non aveva modo di sapere quali. Il resoconto vale soprattutto quando qualcosa va storto.
    it "un'eccezione su una card non ferma le altre né fa saltare la richiesta" do
      buona = planned_workflow
      esplosiva = planned_workflow
      allow(Home::Approvals::Decide).to receive(:call).and_call_original
      allow(Home::Approvals::Decide).to receive(:call)
        .with(hash_including(key: "agent_plan:#{esplosiva.id}"))
        .and_raise(ActiveRecord::StatementTimeout, "SQLite3::BusyException: database is locked")

      result = bulk([ "agent_plan:#{esplosiva.id}", "agent_plan:#{buona.id}" ])

      expect(result.ok?).to be(true)
      expect(result.value.approved).to eq(1)
      expect(result.value.failed).to eq(1)
      expect(result.value.failures.first.key).to eq("agent_plan:#{esplosiva.id}")
      # Il dettaglio del guasto resta nel log: quel testo finisce in un flash a schermo e può
      # portarsi dietro SQL o frammenti di dati.
      expect(result.value.failures.first.message).to eq(I18n.t("member.approvals.errors.card_failed"))
      expect(result.value.failures.first.message).not_to include("database is locked")
      expect(buona.reload.approved_at).to be_present
    end
  end

  describe "payload fuori misura" do
    it "senza nessuna chiave non fa nulla e lo dice" do
      result = bulk([ "", nil ])

      expect(result.err?).to be(true)
      expect(result.error.code).to eq("R422-APPROVAL-004")
    end

    it "oltre il tetto rifiuta invece di tagliare in silenzio" do
      keys = Array.new(described_class::MAX_KEYS + 1) { "review:#{SecureRandom.uuid}" }

      result = bulk(keys)

      expect(result.err?).to be(true)
      expect(result.error.code).to eq("R422-APPROVAL-005")
    end
  end
end
