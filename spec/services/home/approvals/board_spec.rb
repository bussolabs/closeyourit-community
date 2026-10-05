# frozen_string_literal: true

require "rails_helper"

# CYRA-592 — la plancia: una riga per lavorazione e una colonna per ciascuna delle cinque fasi.
# La coda dice una cosa alla volta; qui una riga si legge da sinistra a destra (dove è arrivata) e
# una colonna dall'alto in basso (dove si fermano tutte).
RSpec.describe Home::Approvals::Board do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:, key: "ALFA") }
  let(:visible_projects) { Projects::Project.where(organization_id: organization.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }
  let(:review_status) { create(:ticket_status, :in_review, organization:) }

  before { organization.update_column(:cto_id, account.id) }

  def batch(**overrides)
    Home::Approvals::Queue.call(account:, organization:, visible_projects:, visible_tickets:, **overrides)
  end

  def board(**overrides)
    described_class.call(batch: batch, **overrides)
  end

  def create_ticket(target = project, **attributes)
    create(:ticket, organization:, project: target, **attributes)
  end

  # Una lavorazione col piano pronto: triage fatto, piano consegnato, nessuno l'ha ancora approvato.
  def planned_workflow(target = project, **attributes)
    create(:agent_workflow, ticket: create_ticket(target), triage_requested_at: 3.hours.ago,
                            triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago,
                            planned_at: 1.hour.ago, **attributes)
  end

  def cells_by_phase(row) = row.cells.index_by(&:phase)

  describe "una riga si legge da sinistra a destra (scenario 1)" do
    # CYRA-619 — sei colonne, e sono le sei parole del modello: le stesse con cui la riga, due
    # colonne più in là, dice a che punto è. Prima erano le cinque fasi interne della macchina, e la
    # stessa lavorazione risultava chiamata in due modi sulla stessa riga.
    it "porta i sei passaggi del modello nell'ordine, compresi quelli non ancora raggiunti" do
      planned_workflow

      row = board.page.records.first

      expect(row.cells.map(&:phase)).to eq(Agents::Workflows::PhaseResolver::STEPS)
      expect(row.cells.size).to eq(6)
    end

    it "dice concluse quelle fatte, in attesa quella che aspetta una persona, da fare le altre" do
      planned_workflow

      cells = cells_by_phase(board.page.records.first)

      expect(cells["to_plan"].state).to eq("done")
      expect(cells["plan_to_approve"].state).to eq("current")
      expect(cells.values_at("in_progress", "to_review", "closing", "done").map(&:state))
        .to all(eq("pending"))
    end

    # Il «sei qui» porta ESATTAMENTE la parola che la riga scrive nella colonna dello stato: è quello
    # che toglie di mezzo la traduzione a mente.
    it "il «sei qui» ha la stessa parola dello stato della riga" do
      planned_workflow

      row = board.page.records.first
      corrente = row.cells.find(&:current?)

      expect(corrente.phase).to eq(Agents::Workflows::PhaseResolver.stage(row.state))
    end

    # Una richiesta sui segreti non ha una lavorazione dietro: le colonne restano tutte, spente. Senza,
    # la sua riga avrebbe cinque celle in meno e tutte le altre scivolerebbero di posto.
    it "tiene le sei colonne anche sulle righe che una lavorazione non ce l'hanno" do
      create(:secret_change_request, project:, organization:, requested_by: create(:account))

      row = board.page.records.first

      expect(row.cells.map(&:phase)).to eq(Agents::Workflows::PhaseResolver::STEPS)
      expect(row.cells.map(&:state)).to all(eq("pending"))
      expect(row.cells.map(&:open?)).to all(be(false))
    end
  end

  describe "una colonna si legge dall'alto in basso (scenario 2)" do
    it "mette tutte le lavorazioni ferme sulla stessa fase nella stessa colonna" do
      3.times { planned_workflow }

      rows = board.page.records

      expect(rows.size).to eq(3)
      expect(rows.map { |row| cells_by_phase(row)["plan_to_approve"].state }).to all(eq("current"))
    end
  end

  describe "le celle aprono il passaggio, non il referto di un tentativo (scenario 3)" do
    # CYRA-619 — premendo un quadratino si apriva il referto di un singolo tentativo della macchina:
    # un oggetto interno, a volte l'ultimo di diciannove, che non dice a che punto è il lavoro.
    it "dove c'è una lavorazione ogni passaggio si apre; dove non c'è, nessuno" do
      planned_workflow

      cells = cells_by_phase(board.page.records.first)

      expect(cells.values.map(&:open?)).to all(be(true))
    end

    it "porta il ticket della riga, che è dove il referto si legge" do
      workflow = planned_workflow

      expect(board.page.records.first.ticket_id).to eq(workflow.ticket_id)
    end
  end

  describe "si vede subito su cosa agire (scenario 4)" do
    # Su una lavorazione ferma il segno è ROSSO sulla fase che l'ha bloccata, non «sei qui»: dire
    # «sei qui» dove ci si è inciampati racconterebbe la cosa sbagliata.
    it "segna respinta la fase che ha bloccato la lavorazione, e non ne segna nessuna corrente" do
      workflow = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 4.hours.ago,
                                         triage_started_at: 4.hours.ago, triaged_at: 3.hours.ago,
                                         planned_at: 2.hours.ago, approved_at: 2.hours.ago,
                                         autopilot_started_at: 1.hour.ago,
                                         blocked_at: 30.minutes.ago, blocked_phase: "autopilot", blocked_kind: "attempt_limit")
      create(:agent_attempt, workflow:, organization:, phase: "autopilot", status: :review_failed)

      cells = cells_by_phase(board.page.records.first)

      expect(cells["in_progress"].state).to eq("failed")
      expect(cells.values.map(&:state)).not_to include("current")
    end

    it "porta lo stato della riga una volta sola, quello con cui la coda la conta" do
      planned_workflow

      row = board.page.records.first

      expect(row.state).to eq("awaiting_approval")
      expect(row.item.state).to eq("awaiting_approval")
    end

    it "dice da quando la riga aspetta, con la stessa ancora d'età con cui la coda la ordina" do
      planned_workflow

      row = board.page.records.first

      expect(row.since).to eq(row.item.sort_at)
      expect(row.since).to be_present
    end
  end

  describe "centodieci righe restano leggibili (scenario 5)" do
    let(:other_project) { create(:project, organization:, key: "BETA") }

    # CYRA-899 — the groups follow what the decision asks, in the order the filters list them:
    # every plan to approve in a row, then every review. The project rides on the row instead.
    it "groups rows by what the decision asks, in filter order, with the count" do
      2.times { create_ticket(other_project, status: review_status, reviewer: account) }
      planned_workflow(project)

      groups = board.groups

      expect(groups.map(&:state)).to eq(%w[awaiting_approval review])
      expect(groups.map(&:size)).to eq([ 1, 2 ])
      expect(groups.last.rows.map { |row| row.project.key }).to all(eq("BETA"))
    end

    it "taglia a pagine e i gruppi parlano della sola pagina aperta" do
      3.times { planned_workflow }

      plan = board(per: 2)

      expect(plan.total).to eq(3)
      expect(plan.page.records.size).to eq(2)
      expect(plan.page.total_pages).to eq(2)
      expect(plan.groups.sum(&:size)).to eq(2)
    end

    it "sulla seconda pagina mostra le righe rimaste" do
      3.times { planned_workflow }

      expect(board(per: 2, page: 2).page.records.size).to eq(1)
    end
  end

  # CYRA-899 — where the work piles up: one counter per step, and a click narrows the board to it.
  describe "phase counters and phase filter" do
    def blocked_workflow
      workflow = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 4.hours.ago,
                                         triage_started_at: 4.hours.ago, triaged_at: 3.hours.ago,
                                         planned_at: 2.hours.ago, approved_at: 2.hours.ago,
                                         autopilot_started_at: 1.hour.ago,
                                         blocked_at: 30.minutes.ago, blocked_phase: "autopilot", blocked_kind: "attempt_limit")
      create(:agent_attempt, workflow:, organization:, phase: "autopilot", status: :review_failed)
      workflow
    end

    it "counts every row on the step where it sits, stuck ones included" do
      2.times { planned_workflow }
      blocked_workflow

      counts = board.phase_counts

      expect(counts.keys).to eq(Agents::Workflows::PhaseResolver::STEPS)
      expect(counts["plan_to_approve"]).to eq(2)
      expect(counts["in_progress"]).to eq(1)
      expect(counts["done"]).to eq(0)
    end

    it "keeps only the rows on the chosen step, while the counters still count them all" do
      planned = planned_workflow
      blocked_workflow

      plan = board(phase: "plan_to_approve")

      expect(plan.page.records.map(&:key)).to eq([ "agent_plan:#{planned.id}" ])
      expect(plan.phase).to eq("plan_to_approve")
      expect(plan.phase_counts["in_progress"]).to eq(1)
    end

    it "counts a review without a workflow on the review step, and keeps it under that filter" do
      ticket = create_ticket(status: review_status, reviewer: account)

      plan = board(phase: "to_review")

      expect(plan.phase_counts["to_review"]).to eq(1)
      expect(plan.page.records.map(&:key)).to eq([ "review:#{ticket.id}" ])
    end

    it "ignores a step that does not exist" do
      2.times { planned_workflow }

      plan = board(phase: "nonsense")

      expect(plan.phase).to be_nil
      expect(plan.total).to eq(2)
    end

    it "marks as stuck only the rows stopped on a step" do
      planned_workflow
      blocked_workflow

      stuck = board.page.records.to_h { |row| [ row.state, row.stuck? ] }

      expect(stuck).to eq("awaiting_approval" => false, "review_blocked" => true)
    end
  end

  describe "ordine delle righe" do
    it "dentro un progetto tiene in cima le più vecchie" do
      vecchia = planned_workflow
      vecchia.update_column(:updated_at, 10.days.ago)
      recente = planned_workflow

      expect(board.page.records.map { |row| row.item.key })
        .to eq([ "agent_plan:#{vecchia.id}", "agent_plan:#{recente.id}" ])
    end

    # La palla è a qualcun altro: la riga resta, ma non davanti a ciò che posso davvero fare adesso.
    it "manda in fondo al suo gruppo ciò a cui ho già chiesto precisazioni" do
      chiesto = planned_workflow
      comment = chiesto.ticket.comments.create!(body: "Serve un chiarimento", author: account)
      Ticketing::Event.create!(organization:, ticket: chiesto.ticket, actor: account,
                               actor_name: account.name, action: Home::Approvals::Decide::ASK_ACTION,
                               data: { "comment_id" => comment.id })
      chiesto.update_column(:updated_at, 10.days.ago)
      altra = planned_workflow

      expect(board.page.records.map { |row| row.item.key })
        .to eq([ "agent_plan:#{altra.id}", "agent_plan:#{chiesto.id}" ])
    end
  end

  describe "le famiglie che un ticket ce l'hanno" do
    # Un ticket in revisione ha quasi sempre una lavorazione dietro (l'ha consegnata l'agente): la
    # matrice deve leggerla, o centosette righe su centodieci mostrerebbero cinque puntini spenti.
    it "legge la lavorazione del ticket anche quando la riga è una revisione" do
      ticket = create_ticket(status: review_status, reviewer: account)
      create(:agent_workflow, ticket:, triage_requested_at: 5.hours.ago, triage_started_at: 5.hours.ago,
                              triaged_at: 4.hours.ago, planned_at: 3.hours.ago, approved_at: 3.hours.ago,
                              autopilot_started_at: 2.hours.ago, autopilot_completed_at: 1.hour.ago, candidate_verified_at: 1.hour.ago)

      cells = cells_by_phase(board.page.records.first)

      expect(cells["to_plan"].state).to eq("done")
      expect(cells["plan_to_approve"].state).to eq("done")
      expect(cells["to_review"].state).to eq("current")
    end

    it "legge la lavorazione anche quando la riga è una domanda dell'agente" do
      workflow = create(:agent_workflow, ticket: create_ticket(reviewer: account),
                                         triage_requested_at: 2.hours.ago,
                                         triage_started_at: 2.hours.ago, triaged_at: 1.hour.ago)
      attempt = create(:agent_attempt, workflow:, organization:, phase: "triage")
      create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      cells = cells_by_phase(board.page.records.first)

      expect(cells["to_plan"].state).to eq("current")
      expect(cells["to_plan"].open?).to be(true)
    end
  end

  describe "coda vuota" do
    it "non ha righe né gruppi" do
      plan = board

      expect(plan.total).to be_zero
      expect(plan.groups).to be_empty
      expect(plan.page.records).to be_empty
    end
  end
end
