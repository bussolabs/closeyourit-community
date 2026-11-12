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
  # The repository declares `ci` as its one required check (CYRA-1292): the candidate's verdict carries it green.
  PINNED_CHECKS = { "version" => 2, "checks" => [ { "stage" => "lint", "run" => "bin/rubocop" } ],
                    "remote" => { "provider" => "github", "required_checks" => [ "ci" ] } }.to_yaml.freeze

  def client_su(head_sha, gate_file: PINNED_CHECKS)
    instance_double(Github::Client).tap do |fake|
      allow(fake).to receive(:pull_request_state).and_return({ head_sha: })
      allow(fake).to receive(:repository_file).and_return(gate_file)
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

  it "never approves the delivery of a council ticket by itself" do
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    result = described_class.call(workflow:, candidate:, client: client_su(candidate.head_sha))
    expect(result.value).to be_nil
    expect(workflow.reload.autopilot_approved_at).to be_nil
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

  # CYRA-1291 — before moving on by itself, the delivery is read on the files it really changed.
  describe "checking the files the delivery really changed" do
    def client_with_files(paths, truncated: false)
      client_su(candidate.head_sha).tap do |fake|
        allow(fake).to receive(:pull_request_files).and_return({ paths:, truncated: })
      end
    end

    def freeze_plan_naming(*paths)
      plan = Agents::Plan.create!(
        workflow:, attempt: create(:agent_attempt, workflow:, organization:, phase: "planner"),
        technical_analysis: "Plan", scenarios: [], definition_of_done: [ "RSpec" ], notes: [],
        ticket_snapshot_digest: "snapshot", contract_version: 2,
        content: { "summary" => "Plan", "work_items" => [
          { "id" => "WI-1", "title" => "Change", "files" => paths.map { |path| { "path" => path, "reason" => "edit" } } }
        ] }
      )
      workflow.update!(frozen_plan: plan, plan_frozen_at: Time.current)
    end

    def scope_events = Ticketing::Event.where(ticket:).where("action LIKE 'delivery_scope_%'")

    # The delivery proved its work: these examples are about the files, the proofs have their own below.
    def report_proofs(evidence: [ { "criterion_id" => "DOD-1", "status" => "verified", "evidence" => "seen", "source" => "reported" } ],
                      tests: [ { "name" => "rspec", "status" => "passed" } ])
      attempt.update_columns(result: attempt.result.to_h.merge("work_report" => { "acceptance_evidence" => evidence, "tests" => tests }))
    end

    before do
      freeze_plan_naming("app/models/user.rb")
      report_proofs
    end

    context "when the check is off" do
      it "moves on without reading the files" do
        client = client_with_files(%w[.github/workflows/ci.yml])

        auto_approve(client:)

        expect(client).not_to have_received(:pull_request_files)
        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(scope_events).to be_empty
      end
    end

    context "when the check is a dry run" do
      before { project.update!(delivery_scope_check: "dry_run") }

      it "moves on and records what it would have stopped" do
        auto_approve(client: client_with_files(%w[app/models/user.rb .github/workflows/ci.yml]))

        expect(workflow.reload.autopilot_approved_at).to be_present
        event = scope_events.sole
        expect(event.action).to eq("delivery_scope_would_stop")
        expect(event.data).to include("mode" => "dry_run", "reasons" => %w[sensitive_path_undeclared],
                                      "sensitive" => %w[.github/workflows/ci.yml])
      end

      it "moves on in silence when GitHub does not answer about the files" do
        client = client_su(candidate.head_sha)
        allow(client).to receive(:pull_request_files)
          .and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001", status: :bad_gateway))

        auto_approve(client:)

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(scope_events).to be_empty
      end
    end

    context "when the check is on" do
      before { project.update!(delivery_scope_check: "on") }

      it "leaves to a person a delivery that touches a sensitive file the plan never named" do
        result = auto_approve(client: client_with_files(%w[app/models/user.rb .github/workflows/ci.yml]))

        expect(result).to be_ok
        expect(result.value).to be_nil
        expect(workflow.reload).to have_attributes(autopilot_approved_at: nil, phase: "awaiting_autopilot_approval")
        expect(scope_events.sole).to have_attributes(action: "delivery_scope_stopped")
        expect(Ticketing::Event.where(action: "autopilot_auto_approved")).to be_empty
      end

      it "leaves to a person a delivery that adds a migration, even at low risk" do
        auto_approve(client: client_with_files(%w[app/models/user.rb db/migrate/20261112090000_add_notes.rb]))

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(scope_events.sole.data).to include("reasons" => %w[data_change])
      end

      it "moves on when the delivery only changes the files the plan named" do
        auto_approve(client: client_with_files(%w[app/models/user.rb]))

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(scope_events).to be_empty
      end

      it "moves on and notes the ordinary files changed outside the plan" do
        auto_approve(client: client_with_files(%w[app/models/user.rb app/models/order.rb]))

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(scope_events.sole).to have_attributes(action: "delivery_scope_outside_plan")
        expect(scope_events.sole.data).to include("outside_plan" => %w[app/models/order.rb])
      end

      it "moves on when the approved plan named the sensitive file" do
        freeze_plan_naming("app/models/user.rb", ".github/workflows/ci.yml")

        auto_approve(client: client_with_files(%w[app/models/user.rb .github/workflows/ci.yml]))

        expect(workflow.reload.autopilot_approved_at).to be_present
      end

      it "leaves the delivery to a person when the file list cannot be read" do
        client = client_su(candidate.head_sha)
        allow(client).to receive(:pull_request_files)
          .and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001", status: :bad_gateway))

        auto_approve(client:)

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(scope_events.sole.data).to include("reasons" => %w[files_unknown])
      end

      it "records the tests a delivery removed, without stopping it" do
        client = client_su(candidate.head_sha)
        allow(client).to receive(:pull_request_files).and_return(
          { paths: %w[app/models/user.rb spec/models/user_spec.rb], truncated: false,
            files: [ { path: "spec/models/user_spec.rb", status: "removed", additions: 0, deletions: 40 } ] }
        )
        freeze_plan_naming("app/models/user.rb", "spec/models/user_spec.rb")

        auto_approve(client:)

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(scope_events.sole).to have_attributes(action: "delivery_scope_tests_removed")
        expect(scope_events.sole.data).to include("tests_removed" => %w[spec/models/user_spec.rb], "tests_delta" => -40)
      end

      it "treats a delivery with no frozen plan as naming nothing" do
        workflow.update_columns(frozen_plan_id: nil)

        auto_approve(client: client_with_files(%w[Dockerfile]))

        expect(workflow.reload.autopilot_approved_at).to be_nil
      end
    end
  end

  # CYRA-1292 — a delivery proves each "done when" of its plan, or a person decides.
  describe "checking the proofs the delivery declares" do
    def freeze_plan_with_criteria(*ids)
      plan = Agents::Plan.create!(
        workflow:, attempt: create(:agent_attempt, workflow:, organization:, phase: "planner"),
        technical_analysis: "Plan", scenarios: [], notes: [], ticket_snapshot_digest: "snapshot", contract_version: 2,
        definition_of_done: ids.map { |id| { "id" => id, "text" => "Done when #{id}" } },
        content: { "summary" => "Plan", "work_items" => [] }
      )
      workflow.update!(frozen_plan: plan, plan_frozen_at: Time.current)
    end

    def report(evidence:, tests: [ { "name" => "rspec", "status" => "passed" } ])
      attempt.update_columns(result: attempt.result.to_h.merge("work_report" => { "acceptance_evidence" => evidence, "tests" => tests }))
    end

    def proof(id, status) = { "criterion_id" => id, "status" => status, "evidence" => "seen", "source" => "reported" }

    def evidence_events = Ticketing::Event.where(ticket:).where("action LIKE 'delivery_evidence_%'")

    def quiet_client
      client_su(candidate.head_sha).tap do |fake|
        allow(fake).to receive(:pull_request_files).and_return({ paths: [], truncated: false, files: [] })
      end
    end

    before { freeze_plan_with_criteria("DOD-1", "DOD-2") }

    it "moves on with a missing proof while the check is off" do
      report(evidence: [ proof("DOD-1", "verified"), proof("DOD-2", "missing") ])

      auto_approve

      expect(workflow.reload.autopilot_approved_at).to be_present
      expect(evidence_events).to be_empty
    end

    context "when the check is on" do
      before { project.update!(delivery_scope_check: "on") }

      it "leaves to a person a delivery with a missing proof" do
        report(evidence: [ proof("DOD-1", "verified"), proof("DOD-2", "missing") ])

        result = auto_approve(client: quiet_client)

        expect(result.value).to be_nil
        expect(workflow.reload).to have_attributes(autopilot_approved_at: nil, phase: "awaiting_autopilot_approval")
        expect(evidence_events.sole).to have_attributes(action: "delivery_evidence_stopped")
        expect(evidence_events.sole.data).to include("reasons" => %w[evidence_incomplete], "incomplete" => %w[DOD-2])
      end

      it "leaves to a person a delivery that proves only some criteria of the plan" do
        report(evidence: [ proof("DOD-1", "verified") ])

        auto_approve(client: quiet_client)

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(evidence_events.sole.data).to include("absent" => %w[DOD-2])
      end

      it "leaves to a person a delivery whose tests did not run" do
        report(evidence: [ proof("DOD-1", "verified"), proof("DOD-2", "verified") ],
               tests: [ { "name" => "rspec", "status" => "not_run" } ])

        auto_approve(client: quiet_client)

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(evidence_events.sole.data).to include("reasons" => %w[tests_not_run])
      end

      it "moves on when every criterion is verified and the tests passed" do
        report(evidence: [ proof("DOD-1", "verified"), proof("DOD-2", "verified") ])

        auto_approve(client: quiet_client)

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(evidence_events).to be_empty
      end

      it "records both gates when the files and the proofs both ask for a person" do
        report(evidence: [ proof("DOD-1", "verified"), proof("DOD-2", "partial") ])
        client = client_su(candidate.head_sha)
        allow(client).to receive(:pull_request_files).and_return({ paths: %w[Dockerfile], truncated: false, files: [] })

        auto_approve(client:)

        expect(Ticketing::Event.where(ticket:).pluck(:action))
          .to include("delivery_scope_stopped", "delivery_evidence_stopped")
      end
    end

    context "when the check is a dry run" do
      before { project.update!(delivery_scope_check: "dry_run") }

      it "moves on and records what it would have stopped" do
        report(evidence: [ proof("DOD-1", "verified"), proof("DOD-2", "missing") ])

        auto_approve(client: quiet_client)

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(evidence_events.sole).to have_attributes(action: "delivery_evidence_would_stop")
      end
    end
  end

  # CYRA-1300 — a plan nobody read keeps the fast lane only while its real changes stay as small as promised.
  describe "checking a delivery whose plan took the fast lane" do
    def lane_events = Ticketing::Event.where(ticket:).where(action: "delivery_fast_lane_stopped")

    def client_with_files(*files)
      client_su(candidate.head_sha).tap do |fake|
        allow(fake).to receive(:pull_request_files)
          .and_return({ paths: files.map { |file| file[:path] }, truncated: false, files: })
      end
    end

    def changed(path, additions: 5, deletions: 0) = { path:, status: "modified", additions:, deletions: }

    def take_fast_lane(*paths)
      items = [ { "id" => "WI-1", "title" => "t", "description" => "d", "dependencies" => [],
                  "files" => paths.map { |path| { "path" => path, "line" => 1, "reason" => "r" } } } ]
      plan = Agents::Plan.create!(
        workflow:, attempt:, contract_version: 2, technical_analysis: "x", scenarios: [], notes: [],
        content: { "summary" => "x", "work_items" => items, "rationale" => [], "risks" => [], "open_points" => [],
                   "sources" => [] },
        definition_of_done: [ { "id" => "DOD-1", "text" => "done" } ], ticket_snapshot_digest: "snapshot"
      )
      workflow.update_columns(frozen_plan_id: plan.id)
      Ticketing::RecordActivity.call(ticket:, action: "plan_fast_lane_approved", actor_name: "System",
                                     data: { plan_id: plan.id, files: paths.size, mode: "on" })
    end

    it "does not read the files of a delivery whose plan a person or the supporter approved" do
      client = client_with_files(changed("app/a.rb", additions: 500))

      auto_approve(client:)

      expect(client).not_to have_received(:pull_request_files)
      expect(workflow.reload.autopilot_approved_at).to be_present
    end

    it "moves on when the real changes are as small as the plan promised, tests aside" do
      take_fast_lane("app/a.rb")

      auto_approve(client: client_with_files(changed("app/a.rb", additions: 20), changed("spec/a_spec.rb", additions: 300)))

      expect(workflow.reload.autopilot_approved_at).to be_present
      expect(lane_events).to be_empty
    end

    {
      "more than sixty lines changed" => [ [ [ "app/a.rb", 61 ] ], "too_many_lines" ],
      "more than three files changed" => [ [ [ "app/a.rb", 1 ], [ "app/b.rb", 1 ], [ "app/c.rb", 1 ], [ "app/d.rb", 1 ] ], "too_many_files" ],
      "a file the plan did not name" => [ [ [ "app/a.rb", 1 ], [ "app/z.rb", 1 ] ], "outside_plan" ]
    }.each do |title, (files, reason)|
      it "leaves the delivery to a person with #{title}" do
        take_fast_lane("app/a.rb", "app/b.rb", "app/c.rb", "app/d.rb")

        auto_approve(client: client_with_files(*files.map { |path, lines| changed(path, additions: lines) }))

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(lane_events.sole.data["reasons"]).to include(reason)
      end
    end

    it "leaves the delivery to a person when the file list cannot be read" do
      take_fast_lane("app/a.rb")
      client = client_su(candidate.head_sha)
      allow(client).to receive(:pull_request_files).and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001", status: :bad_gateway))

      auto_approve(client:)

      expect(workflow.reload.autopilot_approved_at).to be_nil
      expect(lane_events.sole.data["reasons"]).to eq(%w[files_unknown])
    end
  end

  # CYRA-1297 — a delivery re-read by the engine that wrote it had no second pair of eyes.
  describe "checking who re-read the delivery" do
    def review_events = Ticketing::Event.where(ticket:).where("action LIKE 'delivery_review_%'")

    def quiet_reviewer_client
      client_su(candidate.head_sha).tap do |fake|
        allow(fake).to receive(:pull_request_files).and_return({ paths: [], truncated: false, files: [] })
      end
    end

    before do
      attempt.update_columns(result: { "work_report" => {
        "acceptance_evidence" => [], "tests" => [ { "name" => "rspec", "status" => "passed" } ]
      } })
    end

    it "moves on when another engine re-read it, with the check on" do
      project.update!(delivery_scope_check: "on")

      auto_approve(client: quiet_reviewer_client)

      expect(workflow.reload.autopilot_approved_at).to be_present
      expect(review_events).to be_empty
    end

    context "when the engine that wrote it re-read it" do
      before { attempt.update_columns(reviewer_runtime: attempt.runtime) }

      it "moves on and says nothing while the check is off" do
        auto_approve(client: quiet_reviewer_client)

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(review_events).to be_empty
      end

      it "moves on in a dry run and records what it would have stopped" do
        project.update!(delivery_scope_check: "dry_run")

        auto_approve(client: quiet_reviewer_client)

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(review_events.sole).to have_attributes(action: "delivery_review_would_stop")
      end

      it "leaves the delivery to a person with the check on" do
        project.update!(delivery_scope_check: "on")

        auto_approve(client: quiet_reviewer_client)

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(review_events.sole).to have_attributes(action: "delivery_review_stopped")
        expect(review_events.sole.data).to include("reasons" => %w[self_review], "engine" => "claude")
      end
    end
  end

  # CYRA-1292 — "no red check" proves nothing until the repository says which checks count.
  describe "checking the checks the repository requires" do
    def checks_events = Ticketing::Event.where(ticket:).where("action LIKE 'delivery_checks_%'")

    def client_with_gate(gate_file)
      client_su(candidate.head_sha, gate_file:).tap do |fake|
        allow(fake).to receive(:pull_request_files).and_return({ paths: [], truncated: false, files: [] })
      end
    end

    def pinned(*names)
      { "version" => 2, "checks" => [ { "stage" => "lint", "run" => "x" } ],
        "remote" => { "provider" => "github", "required_checks" => names } }.to_yaml
    end

    before do
      attempt.update_columns(result: { "work_report" => {
        "acceptance_evidence" => [], "tests" => [ { "name" => "rspec", "status" => "passed" } ]
      } })
    end

    it "moves on without reading the file while the check is off" do
      client = client_with_gate(nil)

      auto_approve(client:)

      expect(client).not_to have_received(:repository_file)
      expect(workflow.reload.autopilot_approved_at).to be_present
    end

    context "when the check is on" do
      before { project.update!(delivery_scope_check: "on") }

      it "leaves to a person a delivery whose repository declares no required checks" do
        auto_approve(client: client_with_gate(nil))

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(checks_events.sole).to have_attributes(action: "delivery_checks_stopped")
        expect(checks_events.sole.data).to include("reasons" => %w[required_checks_undeclared])
      end

      it "leaves to a person a delivery that did not pass a required check" do
        auto_approve(client: client_with_gate(pinned("ci", "migration-versions")))

        expect(workflow.reload.autopilot_approved_at).to be_nil
        expect(checks_events.sole.data).to include("missing" => %w[migration-versions])
      end

      it "reads the file from the branch the pull request targets" do
        client = client_with_gate(pinned("ci"))

        auto_approve(client:)

        expect(client).to have_received(:repository_file)
          .with(anything, "bussolabs/closeyourit-rails", ".closeyourit/quality-gate.yml", ref: "main")
        expect(workflow.reload.autopilot_approved_at).to be_present
      end

      it "leaves the delivery to a person when the file cannot be read" do
        client = client_with_gate(nil)
        allow(client).to receive(:repository_file)
          .and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001", status: :bad_gateway))

        auto_approve(client:)

        expect(workflow.reload.autopilot_approved_at).to be_nil
      end
    end

    context "when the check is a dry run" do
      before { project.update!(delivery_scope_check: "dry_run") }

      it "moves on and records what it would have stopped" do
        auto_approve(client: client_with_gate(nil))

        expect(workflow.reload.autopilot_approved_at).to be_present
        expect(checks_events.sole).to have_attributes(action: "delivery_checks_would_stop")
      end
    end
  end
end
