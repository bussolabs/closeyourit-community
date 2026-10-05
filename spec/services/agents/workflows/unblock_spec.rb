# frozen_string_literal: true

require "rails_helper"

# CYRA-218 — l'uscita da una lavorazione ferma quando NON c'è un piano da approvare.
#
# È il caso normale, non l'eccezione: il blocco scatta perché la revisione ha bocciato la fase, e una
# fase bocciata non produce effetti — un planner bocciato due volte non ha creato nessun Agents::Plan.
# Senza questo servizio le uniche azioni disponibili (approvare il piano, chiedere modifiche) falliscono
# entrambe con `stale`, e l'unica uscita resterebbe annullare tutto.
RSpec.describe Agents::Workflows::Unblock do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end

  before do
    organization.update!(cto:)
    workflow.update!(triage_started_at: 2.minutes.ago, triaged_at: 1.minute.ago,
                     blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit",
                     blocked_reason: "La revisione ha bocciato planner 2 volte su 2")
  end

  it "rimette in coda una lavorazione ferma senza piano da approvare" do
    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_ok
    expect(workflow.reload).to have_attributes(blocked_at: nil, blocked_phase: nil, blocked_reason: nil)
    expect(workflow.ready_execution_phase).to eq("planner")
  end

  # Senza far ripartire il budget, il tentativo concesso dallo sblocco sarebbe l'unico: le bocciature
  # già in archivio sono al tetto, quindi la prima nuova ribloccherebbe subito.
  it "fa ripartire il budget delle bocciature" do
    expect { described_class.call(workflow:, actor: cto) }
      .to change { workflow.reload.review_budget_from }.from(nil).to(be_present)
  end

  # CYRA-761 — un blocco del controllo della proposta lascia il candidato «rifiutato», che non è fra
  # gli stati ritentabili e non ha un prossimo controllo. Senza riarmarlo, lo sblocco toglie il
  # cartello ma nessuno torna a guardare: la scheda dice «va avanti da sola» per sempre.
  context "quando il blocco viene dal controllo della proposta" do
    let(:repository) do
      create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
    end
    let!(:candidato) do
      create(:agent_delivery_candidate, workflow:, repository:, organization:,
                                        repository_full_name: "bussolabs/closeyourit-rails", number: 117,
                                        state: :rejected, next_check_at: nil, last_error_code: "pull_request_missing")
    end

    before do
      workflow.update!(planned_at: 1.minute.ago, approved_at: 1.minute.ago, autopilot_started_at: 1.minute.ago,
                       autopilot_completed_at: 1.minute.ago,
                       blocked_phase: "autopilot", blocked_kind: "candidate_check",
                       blocked_reason: "pull_request_missing on bussolabs/closeyourit-rails#117")
    end

    it "rimette in verifica il candidato rifiutato" do
      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_ok
      expect(candidato.reload).to have_attributes(state: "pending", last_error_code: nil)
      expect(candidato.next_check_at).to be_present
      expect(workflow.reload.blocked_at).to be_nil
    end

    it "risolve il repository collegato nel frattempo a un candidato rifiutato come non collegato" do
      candidato.update!(repository: nil, last_error_code: "repository_not_linked")

      described_class.call(workflow:, actor: cto)

      expect(candidato.reload).to have_attributes(state: "pending", repository_id: repository.id)
    end

    it "lascia intatta la riga già verificata e ne apre una nuova da guardare" do
      candidato.update!(state: :verified_failing, head_sha: "a" * 40, base_ref: "main",
                        verified_at: 1.minute.ago, checks_payload: [])

      expect { described_class.call(workflow:, actor: cto) }
        .to change { workflow.delivery_candidates.count }.by(1)
      expect(candidato.reload).to be_state_verified_failing
      nuova = workflow.delivery_candidates.order(:created_at).last
      expect(nuova).to have_attributes(state: "pending", number: 117, head_sha: nil)
      expect(nuova.next_check_at).to be_present
    end
  end

  it "decide solo il CTO effettivo, come per il piano" do
    stranger = create(:account).tap { |account| create(:membership, account:, organization:) }

    expect(described_class.call(workflow:, actor: stranger).error.code).to eq("R403-WORKFLOW-001")
    expect(workflow.reload.blocked_at).to be_present
  end

  # Sbloccare due volte non è un errore da segnalare: la seconda non ha semplicemente nulla da fare.
  # Un conflitto qui costringerebbe la UI a distinguere due click ravvicinati da un guasto.
  it "su una lavorazione non bloccata non fa nulla e non fallisce" do
    workflow.update!(blocked_at: nil, blocked_phase: nil, blocked_reason: nil)

    expect(described_class.call(workflow:, actor: cto)).to be_ok
  end

  it "non resuscita una lavorazione annullata" do
    workflow.update!(cancelled_at: Time.current)

    expect(described_class.call(workflow:, actor: cto).error.code).to eq("R409-WORKFLOW-001")
    expect(workflow.reload.blocked_at).to be_present
  end

  # CYRA-267 — togliere il blocco NON basta: se la fase bocciata era stata claimata, il suo
  # <fase>_started_at resta scritto e READY_EXECUTION_PHASE_SQL continua a non proporla. Prima di questo
  # lavoro il "riprova" azzerava il blocco e lasciava il ticket fuori dalla coda lo stesso.
  describe "la fase che la revisione ha lasciato ferma" do
    before do
      workflow.update!(triage_started_at: 10.minutes.ago, triaged_at: nil)
      create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)
    end

    it "viene riaperta così il ticket rientra in coda" do
      expect { described_class.call(workflow:, actor: cto) }
        .to change { workflow.reload.ready_execution_phase }.from(nil).to("triage")
      expect(workflow.triage_started_at).to be_nil
    end

    # Sotto il tetto dei tentativi il blocco non è mai scattato, ma la fase claimata è ferma uguale:
    # è il caso che lasciava la lavorazione morta in silenzio.
    it "viene riaperta anche senza che il tetto dei tentativi sia stato raggiunto" do
      workflow.update!(**Agents::Workflow.cleared_block)

      expect { described_class.call(workflow:, actor: cto) }
        .to change { workflow.reload.ready_execution_phase }.from(nil).to("triage")
    end

    it "non tocca una lavorazione annullata" do
      workflow.update!(cancelled_at: Time.current)

      expect(described_class.call(workflow:, actor: cto)).to be_err
      expect(workflow.reload.triage_started_at).to be_present
    end
  end
end
