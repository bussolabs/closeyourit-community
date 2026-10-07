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

    payload = described_class.new(ticket.reload).as_json.dig("workflow", :current_plan)
    expect(payload).to include(approved_by: "Alessio", definition_of_done: [ "RSpec verde" ])
    expect(payload[:approved_at]).to be_within(1.second).of(approved_at)
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

    it "carries nothing when the latest attempt of the phase was not rejected by its review" do
      create(:agent_attempt, organization: ticket.project.organization, workflow:, phase: "autopilot",
                             status: "running", review_status: nil, review: {})

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
