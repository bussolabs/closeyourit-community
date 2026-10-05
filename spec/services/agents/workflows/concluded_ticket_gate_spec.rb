# frozen_string_literal: true

require "rails_helper"

# ── CYRA-630 ──────────────────────────────────────────────────────────────────────────────────────
#
# La stessa decisione si poteva prendere da cinque posti diversi, e ognuno aveva la sua regola: dalla
# prima pagina veniva rifiutata, dalla scheda del ticket passava. Il piano risultava approvato, la
# domanda risposta, il blocco tolto. Finché il ticket restava chiuso non ripartiva niente — ma il
# giorno in cui qualcuno lo riapriva, il lavoro ripartiva da uno stato che nessuno aveva voluto.
#
# Adesso la guardia sta nei service, e da lì nessuna pagina può aggirarla.
RSpec.describe "decidere su un ticket concluso" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:fatto) { create(:ticket_status, :done, organization:) }
  let(:aperto) { create(:ticket_status, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: aperto, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:, role: :owner)
      create(:project_membership, account:, project:)
    end
  end

  before { organization.update!(cto:) }

  def concludi! = ticket.update!(status: fatto)

  # Non c'è una factory per il piano: si scrive come lo scrive chi lo produce, con la versione e il
  # digest dello snapshot che l'approvazione rilegge.
  def piano!
    Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot",
                         technical_analysis: "Il piano", scenarios: [ "Uno" ],
                         definition_of_done: [], notes: [])
  end

  # Ogni service ha la sua strada per arrivarci: quello che conta è che nessuna passi.
  it "il piano non si approva" do
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago)
    piano!
    concludi!

    esito = Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)

    expect(esito).to be_err
    expect(esito.error.code).to eq("R409-WORKFLOW-013")
    expect(workflow.reload.approved_at).to be_nil
  end

  it "le modifiche al piano non si chiedono" do
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago)
    piano!
    concludi!

    esito = Agents::Workflows::RequestPlanChanges.call(workflow:, actor: cto, reason: "Rifallo")

    expect(esito.error.code).to eq("R409-WORKFLOW-013")
  end

  it "una lavorazione ferma non si rimette in moto" do
    workflow.update!(triage_started_at: 2.minutes.ago, blocked_at: 1.minute.ago,
                     blocked_phase: "triage", blocked_kind: "attempt_limit")
    concludi!

    esito = Agents::Workflows::Unblock.call(workflow:, actor: cto)

    expect(esito.error.code).to eq("R409-WORKFLOW-013")
    expect(workflow.reload.blocked_at).to be_present
  end

  it "la lavorazione non si annulla" do
    workflow.update!(triage_started_at: 1.minute.ago)
    concludi!

    esito = Agents::Workflows::Cancel.call(workflow:, actor: cto, reason: "Non serve più")

    expect(esito.error.code).to eq("R409-WORKFLOW-013")
    expect(workflow.reload.cancelled_at).to be_nil
  end

  it "la domanda della macchina non si risponde" do
    clarification = create(:agent_clarification, workflow:, attempt:,
                                                  questions: [ "Quale ambiente?" ])
    concludi!

    esito = Agents::Clarifications::Settle.call(clarification:, author: cto,
                                                answers: { "0" => "production" })

    expect(esito.error.code).to eq("R409-WORKFLOW-013")
    expect(clarification.reload.answered_at).to be_nil
  end

  # CYRA-630 — la review è una decisione come le altre, e su un ticket concluso non si prende. Il
  # caso esiste davvero: uno status può essere `done` E `review_gate` insieme (un «Chiuso dopo
  # revisione» che un'organizzazione si configura), e lì il ticket è concluso e in attesa di
  # revisione nello stesso momento.
  #
  # Prima i due fratelli rispondevano in modo diverso: approvare passava, respingere falliva — ma per
  # caso, perché non trovava uno status in cui respingere, non perché il ticket fosse chiuso. Stessa
  # decisione, due risposte diverse, e nessuna delle due detta per il motivo giusto.
  describe "la review su un ticket già concluso" do
    let(:chiuso_in_review) do
      create(:ticket_status, organization:, category: :done, review_gate: true,
                             label: "Chiuso dopo revisione", code: "closed_review")
    end
    let(:in_review) { create(:ticket, organization:, project:, status: chiuso_in_review, reviewer: cto) }

    it "non si approva" do
      esito = Ticketing::ApproveReview.call(organization:, ticket: in_review, actor: cto, true_actor: cto)

      expect(esito).to be_err
      expect(esito.error.code).to eq("R409-WORKFLOW-013")
      expect(in_review.reload.status).to eq(chiuso_in_review)
    end

    it "non si respinge, e lo dice per il motivo giusto" do
      esito = Ticketing::RejectReview.call(organization:, ticket: in_review, reason: "Manca un test",
                                           actor: cto, true_actor: cto)

      expect(esito).to be_err
      expect(esito.error.code).to eq("R409-WORKFLOW-013")
      expect(in_review.reload.status).to eq(chiuso_in_review)
    end
  end

  # E su un ticket aperto tutto continua a funzionare: la guardia non deve chiudere la porta a chi
  # ha titolo di passarci.
  it "su un ticket aperto la decisione passa come prima" do
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago)
    piano!

    expect(Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)).to be_ok
  end
end
