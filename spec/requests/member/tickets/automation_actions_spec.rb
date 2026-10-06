# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ticket automation actions", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) { create(:account) }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }
  let!(:plan) do
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current, ticket_snapshot_digest: "snapshot")
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [ "Uno" ],
                         definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
  end

  before do
    create(:membership, :owner, organization:, account: cto)
    create(:project_membership, project:, account: cto)
    organization.update!(cto:)
    post login_path, params: { email: cto.email, password: "Secret123!" }
  end

  # CYRA-217: il riquadro automazione rende l'attempt ATTIVO, e chiamava `attempt.agent`, sparito coi typed
  # agent. Un 500 qui non è un dettaglio estetico: il ticket diventa illeggibile proprio mentre lo si lavora.
  it "apre la pagina del ticket mentre una lavorazione è in corso" do
    host = create(:agent_host, organization:, hostname: "minion-1.local")
    create(:agent_attempt, organization:, workflow:, host:, phase: "triage", status: :running)

    # CYRA-219: la macchina che sta lavorando si legge nella scheda Automazione, dove è finito il
    # riquadro che prima stava in sidebar. Il 500 di CYRA-217 nasceva proprio dal render di quel dato.
    get member_ticket_path(ticket, tab: "automation")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("minion-1.local")
  end

  it "approva il piano e rende visibile un errore su una seconda approvazione" do
    post member_ticket_automation_approval_path(ticket)
    expect(response).to redirect_to(member_ticket_path(ticket, tab: "automation"))
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.plan.approved_notice"))

    post member_ticket_automation_approval_path(ticket)
    expect(flash[:alert]).to be_present
  end

  it "richiede modifiche e rende visibile una motivazione mancante" do
    post member_ticket_automation_change_request_path(ticket), params: { reason: "Aggiungi rollback" }
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.plan.changes_notice"))

    post member_ticket_automation_change_request_path(ticket), params: { reason: " " }
    expect(flash[:alert]).to be_present
  end

  it "annulla l'automazione e rende visibile una motivazione mancante" do
    post member_ticket_automation_cancellation_path(ticket), params: { reason: "Stop" }
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.cancelled_notice"))

    workflow.update_columns(cancelled_at: nil, cancelled_by_id: nil, cancellation_reason: nil)
    post member_ticket_automation_cancellation_path(ticket), params: { reason: " " }
    expect(flash[:alert]).to be_present
  end

  # CYRA-218: la via d'uscita quando la fase bocciata non ha prodotto un piano — cioè il caso normale,
  # visto che una fase bocciata non produce effetti. Senza, una lavorazione ferma si può solo annullare.
  it "rimette in coda una lavorazione fermata dal tetto di revisione" do
    workflow.update!(planned_at: nil, blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit",
                     blocked_reason: "review_limit: planner rejected 2 times")

    post member_ticket_automation_unblock_path(ticket)

    expect(response).to redirect_to(member_ticket_path(ticket, tab: "automation"))
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.blocked.retried"))
    expect(workflow.reload.blocked_at).to be_nil
  end

  it "puts stop on the left and retry on the right of a blocked work" do
    workflow.update!(planned_at: nil, blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit",
                     blocked_reason: "review_limit: planner rejected 2 times")

    get member_ticket_path(ticket, tab: "automation")

    body = response.body
    expect(body.index('data-test="automation-cancel"')).to be < body.index('data-test="automation-retry"')
  end

  # CYRA-871 — «Ferma» dalla tabella delle lavorazioni in volo: il rilascio non va in produzione e
  # tiene occupata la fila, finché il CTO non preme «Sblocca e riprova».
  it "ferma un rilascio che aspetta la produzione" do
    create(:github_repository, project:)
    cto.update!(name: "Ada Rossi")
    pronta_per!(workflow, "closer_production")

    post member_ticket_automation_production_hold_path(ticket), params: { confirm: 1 }

    expect(response).to redirect_to(member_ticket_path(ticket, tab: "automation"))
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.production_hold.held"))
    expect(workflow.reload.blocked_kind).to eq("held_by_person")

    get member_ticket_path(ticket, tab: "automation")
    expect(response.body).to include(I18n.t("member.tickets.automation.blocked.body_held", name: "Ada Rossi"))
  end

  # CYRA-675 — la stessa decisione della home, presa dalla scheda: chi apre il ticket per capire non
  # deve tornare in prima pagina per chiedere se quel lavoro serve ancora.
  describe "rivalutazione" do
    it "rimanda alla pianificazione e lo dice" do
      post member_ticket_automation_reassessment_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket, tab: "automation"))
      expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.reassess.requested"))
      expect(workflow.reload).to have_attributes(planned_at: nil, phase: "planning")
    end

    it "il pulsante c'è nella scheda finché il piano aspetta un sì" do
      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include('data-test="automation-reassess"')
    end

    it "sparisce da quando il codice lo scrive la macchina" do
      workflow.update!(approved_at: Time.current, autopilot_started_at: Time.current)

      get member_ticket_path(ticket, tab: "automation")
      expect(response.body).not_to include('data-test="automation-reassess"')

      post member_ticket_automation_reassessment_path(ticket)
      expect(flash[:alert]).to eq(I18n.t("member.home.actions.not_reassessable"))
      expect(workflow.reload.autopilot_started_at).to be_present
    end
  end

  # T1: Reassess and Close the work sat on the page ground, between the steps and the footer.
  it "keeps the reassess and close actions inside a panel" do
    get member_ticket_path(ticket, tab: "automation")

    actions = Nokogiri::HTML(response.body).at_css("[data-test='automation-actions']")
    expect(actions).to be_present
    expect(actions["class"]).to include("rounded-lg", "border", "dark:bg-zinc-900")
  end
end
