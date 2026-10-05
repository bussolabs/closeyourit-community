# frozen_string_literal: true

require "rails_helper"

# CYRA-868 — di decisione per ticket ne resta UNA: il piano. Con i controlli tutti verdi la consegna
# passa da sola; basta uno rosso e torna davanti a una persona, col motivo già scritto.
RSpec.describe Agents::Workflows::AutoApprove do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
  let!(:in_review) { create(:ticket_status, :in_review, organization:, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true) }
  let(:workflow) do
    ticket.agent_workflow.tap do |flow|
      flow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                   candidate_verified_at: 1.minute.ago)
    end
  end
  let(:attempt) do
    create(:agent_attempt, workflow:, organization:, phase: "autopilot", status: :approved,
                           review_status: :accepted, reviewer_runtime: "codex",
                           review: { "status" => "accepted", "summary" => "tutto a posto" })
  end
  let(:candidate) do
    create(:agent_delivery_candidate, :verified_passing, workflow:, attempt:, repository:, organization:,
                                                         repository_full_name: "bussolabs/closeyourit-rails", number: 7)
  end

  # Il codice vivo della proposta è lo stesso che il sistema ha congelato: è il terzo controllo, e
  # senza risposta di GitHub questo servizio non deve decidere niente.
  def client_su(head_sha)
    instance_double(Github::Client).tap do |fake|
      allow(fake).to receive(:pull_request_state).and_return({ head_sha: })
    end
  end

  # Host-first: la pipeline closer è configurata quando esiste una macchina che potrebbe servirla.
  # Senza, approvare accoderebbe il ticket a una coda che nessuno serve (vedi Ticketing::ApproveReview).
  def configure_closer_pipeline
    service_account = create(:account, :service).tap do |account|
      create(:project_membership, account:, project:)
    end
    create(:agent_host, organization:, service_account:, repositories: [ project.key ],
                        runtimes: [ { "name" => "claude", "present" => true } ])
  end

  # Il puntatore alla verifica è quello che Agents::Candidates::Verify scrive promuovendo la riga:
  # senza, il confronto col codice vivo non ha un termine di paragone e non viene nemmeno tentato.
  before do
    configure_closer_pipeline
    workflow.update!(review_candidate_id: candidate.id)
  end

  def auto_approve(client: client_su(candidate.head_sha))
    described_class.call(workflow:, candidate:, client:)
  end

  # ── Scenario 1: tutto verde ───────────────────────────────────────────────────────────────────

  it "controlli verdi e rilettura accettata: la consegna avanza da sola, senza nessun clic" do
    result = auto_approve

    expect(result).to be_ok
    expect(workflow.reload).to have_attributes(autopilot_approved_at: be_present,
                                               phase: "closer_staging_queued")
    expect(ticket.reload.status).to eq(in_progress)
  end

  # Il sì automatico NON si attribuisce a nessuno: l'unica persona che ha deciso qualcosa su questa
  # lavorazione ha approvato il PIANO, e mettere un nome qui direbbe che ne ha approvate due.
  it "non attribuisce il sì a una persona" do
    auto_approve

    expect(workflow.reload.autopilot_approved_by).to be_nil
  end

  # DoD — nella storia del ticket si vede che il passaggio è stato automatico e su quali controlli.
  it "lascia nella storia del ticket il passaggio automatico e i controlli su cui è passato" do
    expect { auto_approve }.to change { Ticketing::Event.where(action: "autopilot_auto_approved").count }.by(1)

    event = Ticketing::Event.find_by(action: "autopilot_auto_approved")
    expect(event.ticket).to eq(ticket)
    expect(event.actor).to be_nil
    expect(event.actor_name).to be_present
    expect(event.data).to include("checks" => [ "ci" ], "checks_count" => 1)
    expect(event.data["review"]).to include("status" => "accepted", "runtime" => "codex")
  end

  # ── Scenario 2: qualcosa non è verde → resta la decisione di una persona ──────────────────────

  # «Ho guardato e di controlli non ce n'è» è una risposta, non un verde: chi approva deve poterlo
  # leggere e decidere lui. La card lo dice già in rosso, quindi il motivo è sotto gli occhi.
  it "nessun controllo configurato: non avanza, il lavoro resta davanti a una persona" do
    candidate.update_columns(state: Agents::DeliveryCandidate.states[:verified_none_configured],
                             checks_payload: [], checks_count: 0)

    expect(auto_approve).to be_ok
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
    expect(ticket.reload.status).to eq(in_review)
  end

  it "rilettura del codice non accettata: non avanza" do
    attempt.update_columns(review_status: Agents::Attempt.review_statuses[:unavailable])

    expect(auto_approve).to be_ok
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  # Il codice si è mosso fra il controllo e adesso: non esiste un sì — né umano né automatico — su
  # codice che nessuno ha guardato. ApproveAutopilot rimette una riga da verificare (CYRA-617).
  it "codice cambiato dopo il controllo: non avanza e la proposta torna da verificare" do
    result = auto_approve(client: client_su("f" * 40))

    expect(result.error.code).to eq("R409-WORKFLOW-005")
    expect(workflow.reload).to have_attributes(phase: "verifying_candidate", candidate_verified_at: nil)
    expect(Ticketing::Event.where(action: "autopilot_auto_approved")).to be_empty
  end

  # Senza una macchina che possa servire i closer, approvare accoderebbe il ticket a una coda che
  # nessuno serve: la decisione resta a chi può anche solo chiuderlo.
  it "senza pipeline closer configurata: non avanza" do
    Agents::Host.update_all(revoked_at: Time.current)

    expect(auto_approve).to be_ok
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  # GitHub non risponde: non si sa cosa c'è dentro la proposta ADESSO, quindi non si decide. Il
  # lavoro resta dov'è e lo sblocca una persona.
  it "GitHub irraggiungibile: non avanza e non scrive niente" do
    muto = instance_double(Github::Client)
    allow(muto).to receive(:pull_request_state)
      .and_raise(Github::Client::Error.new("giù", code: "R502-GITHUB-001", status: :bad_gateway))

    expect(auto_approve(client: muto).error.code).to eq("R409-WORKFLOW-006")
    expect(workflow.reload).to have_attributes(phase: "awaiting_autopilot_approval",
                                               autopilot_approved_at: nil)
  end
end
