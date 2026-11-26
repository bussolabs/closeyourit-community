# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentTicketCandidateSerializer do
  it "include piano corrente, repository e riferimenti opzionali quando presenti" do
    organization = create(:organization)
    project = create(:project, organization:)
    create(:github_repository, project:, full_name: "bussolabs/app", default_branch: "main")
    assignee = create(:account)
    reviewer = create(:account)
    create(:membership, organization:, account: assignee)
    create(:membership, organization:, account: reviewer)
    ticket = create(:ticket, organization:, project:, assignee:, reviewer:, milestone: create(:milestone, project:), with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, organization:, workflow:)
    plan = Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [ "Modifica" ],
                                definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot",
                                change_request: "Aggiungi rollback")

    json = described_class.new(ticket).as_json

    expect(json.dig("workflow", :current_plan)).to include(version: plan.version, technical_analysis: "Piano",
                                                           change_request: "Aggiungi rollback")
    expect(json.fetch("project")).to include(repo: "bussolabs/app", default_branch: "main")
    expect(json.fetch("assignee")).to be_present
    expect(json.fetch("reviewer")).to be_present
    expect(json.fetch("milestone")).to be_present
  end

  # Un piano NON approvato e uno approvato portano gli stessi campi di contenuto: senza l'approvazione
  # esplicita l'host non può distinguerli e finisce per presentarli entrambi come materiale non fidato,
  # lasciando l'autopilot senza la spec che la sua skill esige.
  it "distingue il piano approvato da quello ancora in discussione" do
    ticket = create(:ticket, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, organization: ticket.project.organization, workflow:)
    plan = Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [],
                                definition_of_done: [ "RSpec verde" ], notes: [], ticket_snapshot_digest: "snapshot")

    expect(described_class.new(ticket).as_json.dig("workflow", :current_plan))
      .to include(approved_at: nil, approved_by: nil)

    cto = create(:account, name: "Alessio")
    create(:membership, organization: ticket.project.organization, account: cto)
    approved_at = Time.current
    plan.update!(approved_by: cto, approved_at:)
    workflow.update!(approved_at:)

    payload = described_class.new(ticket.reload).as_json.dig("workflow", :current_plan)
    expect(payload).to include(approved_by: "Alessio", definition_of_done: [ "RSpec verde" ])
    expect(payload[:approved_at]).to be_within(1.second).of(approved_at)
  end

  # CYRA-1362 — the delivery said the approved plan does not apply: the work goes back to planning and the plan
  # keeps who approved it and when. Planning must read it as the previous plan with the reason, not as approved.
  describe "a plan the delivery rejected" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }

    before do
      create(:github_repository, project:, full_name: "bussolabs/app", default_branch: "main", release_probe: :merge)
      workflow.update!(ticket_snapshot_digest: "snapshot", triaged_at: 1.hour.ago, planned_at: 1.hour.ago)
      Agents::Plan.create!(workflow:, attempt: create(:agent_attempt, organization:, workflow:), technical_analysis: "Piano",
                           scenarios: [], definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")
      cto = create(:account, name: "Alessio").tap do |account|
        create(:membership, account:, organization:)
        create(:project_membership, account:, project:)
      end
      organization.update!(cto:)
      expect(Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)).to be_ok
    end

    it "still reaches development as approved, with the frozen version and its constraints" do
      json = described_class.new(ticket.reload).as_json

      expect(json.dig("workflow", :execution_phase)).to eq("autopilot")
      expect(json.dig("workflow", :frozen_plan_version)).to eq(workflow.reload.frozen_plan.version)
      expect(json.dig("workflow", :current_plan)).to include(
        approved_by: "Alessio",
        candidate_items: [ { "repo" => "bussolabs/app", "base" => "main" } ],
        completion_probe: { "kind" => "merge", "repo" => "bussolabs/app" }
      )
      expect(json.dig("workflow", :current_plan, :approved_at)).to be_present
    end

    it "reaches planning without the approval, without the frozen constraints, with the reason to follow" do
      workflow.plans.last.update!(change_request: "The model allows a single owner")
      workflow.update!(planned_at: nil, approved_at: nil, approved_by: nil)

      json = described_class.new(ticket.reload).as_json

      expect(json.dig("workflow", :execution_phase)).to eq("planner")
      expect(json.dig("workflow", :frozen_plan_version)).to be_nil
      expect(json.dig("workflow", :current_plan)).to include(
        approved_at: nil, approved_by: nil, candidate_items: nil, completion_probe: nil,
        change_request: "The model allows a single owner"
      )
      # The approval stays on record: only what travels to the machine changes.
      expect(workflow.plans.last.approved_at).to be_present
    end
  end

  # CYAU-177 — le due decisioni che una persona ha congelato approvando il piano (CYRA-610) devono
  # arrivare alla sessione dell'agente: è lei a doverle rispettare, e finora non le riceveva — deduceva
  # da sé dove aprire la proposta e quando dirsi finita.
  it "porta alla sessione il vincolo congelato all'approvazione, e quale versione è quella congelata" do
    organization = create(:organization)
    project = create(:project, organization:)
    create(:github_repository, project:, full_name: "bussolabs/app", default_branch: "main",
                               release_probe: :merge)
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot", triaged_at: 1.hour.ago, planned_at: 1.hour.ago)
    attempt = create(:agent_attempt, organization:, workflow:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [],
                         definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")
    cto = create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
    organization.update!(cto:)

    expect(Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)).to be_ok

    json = described_class.new(ticket.reload).as_json
    expect(json.dig("workflow", :current_plan)).to include(
      candidate_items: [ { "repo" => "bussolabs/app", "base" => "main" } ],
      completion_probe: { "kind" => "merge", "repo" => "bussolabs/app" }
    )
    # `current_plan` è `plans.last`, non per forza il congelato: senza questa versione l'host non ha
    # modo di verificarlo, e comporrebbe il vincolo da un piano che nessuno ha approvato.
    expect(json.dig("workflow", :frozen_plan_version)).to eq(workflow.reload.frozen_plan.version)
  end

  it "lascia nulli il vincolo e la versione congelata finché nessuno ha approvato" do
    ticket = create(:ticket, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, organization: ticket.project.organization, workflow:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [],
                         definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")

    json = described_class.new(ticket).as_json

    expect(json.dig("workflow", :current_plan)).to include(candidate_items: nil, completion_probe: nil)
    expect(json.dig("workflow", :frozen_plan_version)).to be_nil
  end

  # CYAU-249 — when a person last restarted the attempt budget, so the machine restarts its own series too.
  it "carries when a person last restarted the attempt budget" do
    ticket = create(:ticket, with_agent_workflow: true)
    restarted = Time.zone.parse("2026-10-08 19:30:00")
    ticket.agent_workflow.update!(**Agents::Workflow.cleared_block(restarted))

    json = described_class.new(ticket.reload).as_json

    expect(Time.zone.parse(json.dig("workflow", :budget_from).to_s)).to eq(restarted)
  end

  it "mantiene null i riferimenti opzionali e il repository assente" do
    ticket = create(:ticket, assignee: nil, reviewer: nil, milestone: nil, with_agent_workflow: true)

    json = described_class.new(ticket).as_json

    expect(json.dig("workflow", :current_plan)).to be_nil
    expect(json.fetch("project")).to include(repo: nil, default_branch: nil)
    expect(json.fetch("assignee")).to be_nil
    expect(json.fetch("reviewer")).to be_nil
    expect(json.fetch("milestone")).to be_nil
  end

  # Host-first (CYAU-87): il candidate espone la execution_phase AUTORITATIVA pre-claim (uno dei 5
  # PhaseProfile::PHASES = `ready_execution_phase`), NON lo stato FSM di `#phase` (che per il planner-ready
  # è `planning`/`review_blocked`, non mappabile). Allinea il vocabolario pre-claim (candidate) a quello
  # post-claim (lease.execution_phase) → l'automator deriva runtime/skill/sandbox da PhaseProfile senza
  # dover indovinare dallo stato FSM.
  it "espone la execution_phase autoritativa (ready_execution_phase) accanto allo stato FSM" do
    ticket = create(:ticket, with_agent_workflow: true)
    workflow = ticket.agent_workflow

    json = described_class.new(ticket).as_json

    expect(json.dig("workflow", :phase)).to eq("triage_queued")
    expect(json.dig("workflow", :execution_phase)).to eq("triage")
    expect(json.dig("workflow", :execution_phase)).to eq(workflow.ready_execution_phase)
  end

  it "riflette la execution_phase corrente quando il workflow è avanzato al planner" do
    ticket = create(:ticket, with_agent_workflow: true)
    # triaged ma non ancora pianificato → ready_execution_phase = planner, ma #phase = planning (non planner_queued)
    ticket.agent_workflow.update!(triaged_at: Time.current)

    json = described_class.new(ticket).as_json

    expect(json.dig("workflow", :phase)).to eq("planning")
    expect(json.dig("workflow", :execution_phase)).to eq("planner")
  end

  # CYRA-764x — il commit che una persona ha approvato viaggia con il candidato: senza, la fase di
  # rilascio non ha «il commit approvato preso dal server» che la sua skill esige e o si ferma o se lo
  # inventa dal ramo. L'host lo legge da `workflow.frozen_candidate` (repo, number, head_sha, base_ref).
  it "porta il commit approvato come frozen_candidate quando la consegna è stata approvata" do
    organization = create(:organization)
    project = create(:project, organization:)
    repository = create(:github_repository, project:, full_name: "bussolabs/app", default_branch: "main")
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot")
    candidato = create(:agent_delivery_candidate, :verified_passing, workflow:, organization:, repository:,
                                                  repository_full_name: "bussolabs/app", number: 117,
                                                  head_sha: "6" * 40, base_ref: "main")
    workflow.update!(review_candidate: candidato)

    json = described_class.new(ticket.reload).as_json

    expect(json.dig("workflow", :frozen_candidate)).to eq(repo: "bussolabs/app", number: 117,
                                                          head_sha: "6" * 40, base_ref: "main")
  end

  it "non inventa un frozen_candidate quando nessuna consegna è stata approvata" do
    ticket = create(:ticket, with_agent_workflow: true)
    ticket.agent_workflow.update!(ticket_snapshot_digest: "snapshot")

    expect(described_class.new(ticket).as_json.dig("workflow", :frozen_candidate)).to be_nil
  end
  # CYAU-236 — a retry after a review that asked for changes must see what the review found. Without it
  # the next attempt only had the approved plan, found its own open PR, declared the work "already
  # delivered" and fixed nothing until the attempt limit stopped the workflow.
  describe "rework after a rejected review" do
    let(:ticket) { create(:ticket, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }

    def review(findings)
      { "depth" => "diff", "status" => "changes_requested", "findings" => findings }
    end

    before { workflow.update!(triaged_at: 1.hour.ago, planned_at: 1.hour.ago, approved_at: 1.hour.ago) }

    it "carries the blocking findings of the latest rejected attempt of the ready phase" do
      create(:agent_attempt, organization: ticket.project.organization, workflow:, phase: "autopilot",
                             status: "review_failed", review_status: "changes_requested",
                             review: review([
                               { "severity" => "major", "title" => "Trailing newline accepted", "detail" => "Use \\z" },
                               { "severity" => "info", "title" => "Naming nit", "detail" => "ignore" }
                             ]))

      rework = described_class.new(ticket.reload).as_json.dig("workflow", :rework)

      expect(rework).to include(phase: "autopilot")
      expect(rework[:findings]).to eq([ { severity: "major", title: "Trailing newline accepted", detail: "Use \\z" } ])
    end

    it "carries the findings of a rejected attempt whose review status is not changes_requested" do
      create(:agent_attempt, organization: ticket.project.organization, workflow:, phase: "autopilot",
                             status: "review_failed", review_status: "unavailable",
                             review: review([ { "severity" => "major", "title" => "Bug", "detail" => "Fix it" } ]))

      expect(described_class.new(ticket.reload).as_json.dig("workflow", :rework, :findings).size).to eq(1)
    end

    it "still carries the findings once the claim has opened the next attempt" do
      org = ticket.project.organization
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "review_failed",
                             review_status: "unavailable",
                             review: review([ { "severity" => "major", "title" => "Bug", "detail" => "Fix it" } ]),
                             created_at: 10.minutes.ago)
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "stale", created_at: 5.minutes.ago)
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "running")

      expect(described_class.new(ticket.reload).as_json.dig("workflow", :rework, :findings).size).to eq(1)
    end

    # CYRA-1195 — the fix round after red checks tells the agent which checks failed.
    it "carries the failing checks of the delivered pull request in the CI fix round" do
      workflow.update!(autopilot_started_at: nil, ci_fix_requested_at: Time.current)
      create(:agent_delivery_candidate, workflow:, organization: ticket.project.organization,
                                        repository_full_name: "bussolabs/app", number: 9, state: :verified_failing,
                                        head_sha: "b" * 40, base_ref: "main", verified_at: Time.current,
                                        checks_count: 2, last_checked_at: Time.current,
                                        checks_payload: [
                                          { "__typename" => "CheckRun", "name" => "rspec", "conclusion" => "FAILURE",
                                            "detailsUrl" => "https://github.com/bussolabs/app/actions/runs/1" },
                                          { "__typename" => "CheckRun", "name" => "lint", "conclusion" => "SUCCESS" }
                                        ])

      rework = described_class.new(ticket.reload).as_json.dig("workflow", :rework)

      expect(rework).to include(phase: "autopilot")
      expect(rework[:findings].size).to eq(1)
      expect(rework[:findings].first).to include(severity: "major")
      expect(rework[:findings].first[:title]).to include("rspec")
      expect(rework[:findings].first[:detail]).to include("bussolabs/app#9", "actions/runs/1", "sync-main.sh")
    end

    # CYRA-1197 — the supporter sent stopped work back: its guidance reaches the first attempt after the retry.
    it "carries the supporter's guidance once, to the first attempt after its retry" do
      org = ticket.project.organization
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "failed", created_at: 10.minutes.ago)
      Agents::SupporterDecision.create!(organization: org, workflow:, target_type: "consult", target_id: workflow.id,
                                        target_digest: "sha256:x", outcome: "retried", engine: "codex", risk_score: 3,
                                        evidence: { "guidance" => "Use the factory in spec/factories/items.rb." })
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "running")

      rework = described_class.new(ticket.reload).as_json.dig("workflow", :rework)
      expect(rework[:findings]).to eq([ { severity: "major", title: "Supporter guidance after the stop",
                                          detail: "Use the factory in spec/factories/items.rb." } ])

      workflow.attempts.status_running.update_all(status: "failed")
      expect(described_class.new(ticket.reload).as_json.dig("workflow", :rework)).to be_nil
    end

    # CYRA-1197 — the notes the supporter wrote when it approved the plan reach the first coding attempt.
    it "carries the supporter's notes on the approved plan to the first coding attempt" do
      org = ticket.project.organization
      Agents::SupporterDecision.create!(organization: org, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                        target_digest: "sha256:p", outcome: "approved", engine: "codex", risk_score: 4,
                                        evidence: { "guidance" => "Add the migration that only adds the column." })
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "running")

      rework = described_class.new(ticket.reload).as_json.dig("workflow", :rework)
      expect(rework[:findings]).to eq([ { severity: "major", title: "Supporter notes on the approved plan",
                                          detail: "Add the migration that only adds the column." } ])
    end

    # CYRA-1306 — a person rejected a delivery the automatic review had accepted and sent it back to the
    # agent: without the reason the next round only had the plan, and delivered the same commit again.
    describe "a person's rejection sent back to the agent" do
      let(:org) { ticket.project.organization }

      def reject(mode:, reason: "Add one more test case: calling it twice gives the same result.")
        Ticketing::RecordActivity.call(ticket:, action: "review_rejected",
                                       data: { reason:, mode:, status: { from: "In Review", to: "In Progress" } })
      end

      it "carries the reason to the first attempt after the rejection" do
        create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "approved",
                               review_status: "accepted", created_at: 10.minutes.ago)
        reject(mode: "rework")
        create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "running")

        rework = described_class.new(ticket.reload).as_json.dig("workflow", :rework)

        expect(rework).to include(phase: "autopilot")
        expect(rework[:findings]).to eq([ { severity: "major",
                                            title: "A person rejected the delivery and asked for this change",
                                            detail: "Add one more test case: calling it twice gives the same result." } ])
      end

      it "carries it once: not after an attempt that already answered it" do
        reject(mode: "rework")
        create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "approved",
                               review_status: "accepted", created_at: 1.minute.from_now)

        expect(described_class.new(ticket.reload).as_json.fetch("workflow")).not_to have_key(:rework)
      end

      it "does not carry the reason of a rejection set aside for a person" do
        create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "approved",
                               review_status: "accepted", created_at: 10.minutes.ago)
        reject(mode: "hold")

        expect(described_class.new(ticket.reload).as_json.fetch("workflow")).not_to have_key(:rework)
      end

      it "travels next to the findings of an automatic review that also rejected" do
        create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: "review_failed",
                               review_status: "changes_requested", created_at: 10.minutes.ago,
                               review: review([ { "severity" => "major", "title" => "Bug", "detail" => "Fix it" } ]))
        reject(mode: "rework")

        titles = described_class.new(ticket.reload).as_json.dig("workflow", :rework, :findings).pluck(:title)
        expect(titles).to eq([ "Bug", "A person rejected the delivery and asked for this change" ])
      end
    end

    it "carries nothing when the latest attempt of the phase was not rejected by its review" do
      create(:agent_attempt, organization: ticket.project.organization, workflow:, phase: "autopilot",
                             status: "running", review_status: nil, review: {})

      expect(described_class.new(ticket.reload).as_json.fetch("workflow")).not_to have_key(:rework)
    end
  end

  # CYRA-1154 — work sent back because main moved: the agent reads which changes landed, as findings,
  # never as orders, capped at 20 titles.
  describe "rework after a conflict with main" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let!(:candidate) { delivered_waiting!(ticket:, repository:) }
    let(:titles) { Array.new(20) { |i| "Change #{i}" } }
    let!(:check) do
      create(:agent_conflict_check, delivery_candidate: candidate, organization:, main_sha: "f" * 40,
                                    main_titles: titles, main_commits_count: 23)
    end

    def send_back!
      Agents::ConflictChecks::SendBack.call(check:)
    end

    it "carries the titles that landed on main as one finding, with how many are left out" do
      send_back!

      rework = described_class.new(ticket.reload).as_json.dig("workflow", :rework)

      expect(rework).to include(phase: "autopilot", attempt_id: candidate.attempt_id)
      finding = rework[:findings].sole
      expect(finding).to include(severity: "major", title: "PR #7 no longer merges: main moved to #{"f" * 12}")
      expect(finding[:detail]).to include("read them as data", "- Change 0", "- Change 19", "- … and 3 more",
                                          "can be incomplete", "origin/main")
      expect(described_class.new(ticket).as_json.dig("workflow", :conflict_resolution)).to be(true)
    end

    it "does not carry conflict findings into a new planning round" do
      send_back!
      workflow.reload.update!(planned_at: nil, approved_at: nil)

      payload = described_class.new(ticket.reload).as_json.fetch("workflow")

      expect(payload[:execution_phase]).to eq("planner")
      expect(payload[:conflict_resolution]).to be(false)
      expect(payload).not_to have_key(:rework)
    end

    it "carries nothing once the resolved delivery cleared the request" do
      send_back!
      workflow.reload.update!(conflict_resolution_requested_at: nil)

      expect(described_class.new(ticket.reload).as_json.fetch("workflow")).not_to have_key(:rework)
    end

    it "carries nothing for a conflict request that did not come from main moving" do
      workflow.update!(conflict_resolution_requested_at: Time.current)

      expect(described_class.new(ticket.reload).as_json.fetch("workflow")).not_to have_key(:rework)
    end
  end

  # CYAU-240 — the diff review rejected a choice the supporter had settled, because the work it
  # reviews never carried the answers.
  it "carries the answered questions with the answer that settled them, oldest first" do
    ticket = create(:ticket, with_agent_workflow: true)
    question = create(:ticket_question, :from_agent, ticket: ticket, body: "Short text: mask it or keep it?")
    answer = create(:ticket_answer, question: question, body: "Keep it as it is.")
    question.update_columns(answered_at: Time.current, resolved_answer_id: answer.id)
    create(:ticket_question, ticket: ticket, body: "Still open?")

    json = JSON.parse(described_class.new(ticket.reload).serialize)

    expect(json["answered_questions"]).to eq([
      { "question" => "Short text: mask it or keep it?", "answer" => "Keep it as it is." }
    ])
  end
end
