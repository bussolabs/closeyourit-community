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

  # CYRA-1366 — a trial release stopped before the staging check is looked at again: a tag sent again counts.
  it "looks at the trial release again when it stopped the staging check" do
    workflow.update!(closer_staging_completed_at: 10.minutes.ago, closer_staging_next_check_at: nil,
                     blocked_phase: "closer_staging", blocked_kind: "staging_deploy",
                     blocked_reason: "staging_proof: staging_run_failed")

    described_class.call(workflow:, actor: cto)

    expect(workflow.reload).to have_attributes(blocked_at: nil, closer_staging_next_check_at: be_present)
  end

  # CYRA-1367 — a retry after a failed production release looks at the release again, for a full hour.
  describe "when the release check stopped the work" do
    let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
    let!(:done) { create(:ticket_status, :done, organization:) }
    let(:sealed_sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }
    let!(:probe) do
      workflow.probes.create!(kind: "deploy_smoke", bound_at: 2.hours.ago, next_check_at: 1.minute.ago, checks_count: 30,
                              expected: { "version" => "v0.30.0", "sha" => sealed_sha, "repo" => repository.full_name })
    end

    def release_client(deploy:, smoke:, run_conclusion:)
      jobs = [ { "name" => "deploy / deploy-production", "conclusion" => deploy, "run_attempt" => 1 },
               { "name" => "deploy / smoke-prod", "conclusion" => smoke, "run_attempt" => 1 } ]
      instance_double(Github::Client).tap do |client|
        allow(client).to receive_messages(tag_commit: sealed_sha, commit_contained?: false, workflow_run_jobs: jobs,
                                          workflow_runs: [ { "id" => 7, "conclusion" => run_conclusion } ])
      end
    end

    def observe(client) = Agents::Probes::Observe.call(probe: probe.reload, client:)

    let(:ticket) { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) }

    before do
      workflow.update!(**Agents::Workflow.cleared_block)
      pronta_per!(workflow, "closer_production")
      workflow.update!(closer_production_started_at: 3.hours.ago, closer_production_completed_at: 2.hours.ago)
      observe(release_client(deploy: "failure", smoke: "skipped", run_conclusion: "failure"))
      workflow.reload
    end

    it "starts the check again with a full hour and no attempts counted" do
      expect(workflow).to have_attributes(blocked_kind: "release_probe", blocked_phase: "closer_production")

      freeze_time do
        described_class.call(workflow:, actor: cto)

        expect(probe.reload).to have_attributes(bound_at: Time.current, next_check_at: Time.current,
                                                checks_count: 0, last_error_code: nil, closed_at: nil)
      end
      expect(workflow.reload.blocked_at).to be_nil
    end

    # AC-1
    it "closes the ticket once the rerun on GitHub succeeded" do
      described_class.call(workflow:, actor: cto)
      project.releases.create!(version: "v0.30.0", environment: "production", sha: sealed_sha, proved_at: Time.current)

      observe(release_client(deploy: "success", smoke: "success", run_conclusion: "success"))

      expect(workflow.reload).to have_attributes(completed_at: be_present, blocked_at: nil)
      expect(ticket.reload.status).to eq(done)
    end

    # AC-2: without the new hour the expired check would stop the work at its first look.
    it "waits for a rerun still in progress instead of stopping again" do
      described_class.call(workflow:, actor: cto)

      observe(release_client(deploy: nil, smoke: nil, run_conclusion: nil))

      expect(workflow.reload.blocked_at).to be_nil
      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "release_run_missing")
    end

    # AC-4: nothing was rerun, so the same stop comes back and nothing is done.
    it "stops again for the same reason when nobody reran the release" do
      described_class.call(workflow:, actor: cto)

      observe(release_client(deploy: "failure", smoke: "skipped", run_conclusion: "failure"))

      expect(workflow.reload).to have_attributes(blocked_kind: "release_probe", completed_at: nil)
      expect(workflow.blocked_reason).to include("release_run_failed")
      expect(ticket.reload.status).not_to eq(done)
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
