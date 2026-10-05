# frozen_string_literal: true

require "rails_helper"

# Decisioni di review dalla ticket-show. rack_test non applica i CSS: il <dialog> chiuso è
# comunque pilotabile (come per le viste salvate) — l'apertura reale è JS (ui--dialog).
RSpec.describe "Member ticket review", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:in_review) { create(:ticket_status, :in_review, organization: org, code: "in_review", position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization: org, code: "in_progress", position: 1) }
  let!(:resolved) { create(:ticket_status, :done, organization: org, code: "resolved", position: 3) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let!(:ticket) { create(:ticket, organization: org, project: project, status: in_review, with_agent_workflow: true) }
  # CYRA-557 — i pulsanti di decisione compaiono solo dove c'è il racconto del lavoro consegnato:
  # senza, la pagina dice che non c'è ancora niente da approvare e non offre niente da premere.
  let!(:report) { create(:ticket_report, ticket: ticket, organization: org, body: "Fatto, con i test.") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "rifiuta la review col motivo: status in progress, commento ed evento in timeline" do
    sign_in_as(owner)
    visit member_ticket_path(ticket, tab: "discussion")
    expect_test "ticket-review-reject"

    within_test "ticket-review-reject-modal" do
      fill_test "ticket-review-reject-reason", with: "Manca il test sul caso limite"
      click_on_test "ticket-review-reject-hold"
    end

    expect(ticket.reload.status).to eq(in_progress)
    expect(ticket.comments.last.body).to eq("Manca il test sul caso limite")
    expect(ticket.events.where(action: "review_rejected")).to exist
    # Timeline: commento col motivo + riga evento; badge stato aggiornato.
    within_test "member-ticket-timeline" do
      expect(page).to have_text("Manca il test sul caso limite")
    end
    expect_test "ticket-status-badge"
    expect(find("[data-test='ticket-status-badge']")).to have_text(in_progress.label)
  end

  # I due rifiuti stanno nel dialog e non nell'header: la scelta si fa dopo aver scritto il motivo, e
  # l'header ha già una regola sua sulle azioni. Qui conta che siano due gesti distinti e che quello
  # "rimanda" rimetta davvero la fase in coda — il rifiuto che non ripartiva era il difetto.
  it "rimanda la lavorazione all'agente: la fase conclusa torna reclamabile" do
    now = Time.current
    ticket.agent_workflow.update!(triage_started_at: now, triaged_at: now, planned_at: now,
                                  approved_at: now, autopilot_started_at: now, autopilot_completed_at: now, candidate_verified_at: now)
    expect(ticket.agent_workflow.ready_execution_phase).to be_nil

    sign_in_as(owner)
    visit member_ticket_path(ticket)

    within_test "ticket-review-reject-modal" do
      fill_test "ticket-review-reject-reason", with: "Il test che hai scritto non passa"
      click_on_test "ticket-review-reject-rework"
    end

    expect(ticket.reload.status).to eq(in_progress)
    expect(ticket.agent_workflow.reload.ready_execution_phase).to eq("autopilot")
  end

  it "su un ticket senza lavorazione automatica il rifiuto resta un pulsante solo" do
    plain = create(:ticket, organization: org, project: project, status: in_review)
    create(:ticket_report, ticket: plain, organization: org, body: "Fatto a mano.")
    sign_in_as(owner)
    visit member_ticket_path(plain)

    expect(page).not_to have_css("[data-test='ticket-review-reject-rework']")
    within_test "ticket-review-reject-modal" do
      fill_test "ticket-review-reject-reason", with: "Manca il caso limite"
      click_on_test "ticket-review-reject-submit"
    end

    expect(plain.reload.status).to eq(in_progress)
  end

  # CYRA-389 — Scenario 1: un lavoro consegnato non va bene e la motivazione è tutto il valore del
  # gesto. Prima si potevano scrivere solo 240 caratteri: oltre quella misura il testo non veniva
  # salvato da nessuna parte visibile, e il perché del respingimento finiva fuori dal prodotto.
  it "una motivazione lunga si salva per intero e si legge nel resoconto" do
    motivo = "Il caso limite non è coperto e la verifica va rifatta. " * 12
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    within_test "ticket-review-reject-modal" do
      fill_test "ticket-review-reject-reason", with: motivo
      click_on_test "ticket-review-reject-hold"
    end

    expect(ticket.reload.status).to eq(in_progress)
    expect(ticket.current_report.body).to eq(motivo.strip)

    visit member_ticket_path(ticket, tab: "report")
    within_test "ticket-report-meta" do
      expect(page).to have_text(I18n.t("member.tickets.show.report_rejection"))
    end
    within_test "ticket-report" do
      expect(page).to have_text("Il caso limite non è coperto")
    end
  end

  it "approva la review: status sul primo done, evento in timeline" do
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    click_on_test "ticket-review-approve"

    expect(ticket.reload.status).to eq(resolved)
    expect(ticket.events.where(action: "review_approved")).to exist
    expect(find("[data-test='ticket-status-badge']")).to have_text(resolved.label)
  end

  it "ticket NON in review → nessun pulsante di decisione" do
    ticket.update!(status: in_progress)
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    expect(page).not_to have_css("[data-test='ticket-review-approve']")
    expect(page).not_to have_css("[data-test='ticket-review-reject']")
  end
end
