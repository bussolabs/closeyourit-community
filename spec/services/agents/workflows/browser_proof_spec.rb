# frozen_string_literal: true

require "rails_helper"

# CYRA-1302 — a plan that declares a proof to run in a browser waits for a person before production.
RSpec.describe Agents::Workflows::BrowserProof do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }

  before { versioni_uscite("v1.0.0") }

  def waiting_for_production(kinds:, approved: true)
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = pronta_per!(ticket.agent_workflow, "closer_production")
    workflow.update!(closer_production_approved_at: nil)
    create(:agent_attempt, workflow:, organization:, phase: "closer_staging", status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => "a" * 40 })
    plan(workflow, kinds:, approved:)
    workflow
  end

  def plan(workflow, kinds:, approved: true)
    attempt = create(:agent_attempt, organization:, workflow:, phase: "planner")
    done = kinds.each_with_index.map do |kind, index|
      criterion = { "id" => "DOD-#{index + 1}", "text" => "The button reads Save" }
      kind ? criterion.merge("verification" => { "kind" => kind, "how" => "Open the page and read the button" }) : criterion
    end
    Agents::Plan.create!(
      workflow:, attempt:, contract_version: 2, technical_analysis: "Change one label.", scenarios: [], notes: [],
      content: { "summary" => "Change one label.", "work_items" => [], "rationale" => [], "risks" => [],
                 "open_points" => [], "sources" => [] },
      definition_of_done: done, ticket_snapshot_digest: "snapshot", approved_at: (Time.current if approved)
    )
  end

  def ready_host
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                     project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def queue_head = Agents::TicketQueues::Candidates.new(project:, host: ready_host).head_id

  before { project.update!(production_hold_hours: 0) }

  context "with the switch on" do
    before { project.update!(browser_proof_go_ahead: true) }

    it "stops a plan with a browser proof before production and keeps it out of the queue" do
      workflow = waiting_for_production(kinds: [ "test", "browser" ])

      expect(queue_head).to be_nil
      Agents::Workflows::RequestProductionApproval.call(workflow:)

      expect(workflow.reload).to have_attributes(blocked_phase: "closer_production", blocked_kind: "production_approval")
    end

    it "lets it go once a person gave the go-ahead" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      workflow.update!(closer_production_approved_at: Time.current)

      expect(queue_head).to eq(workflow.ticket_id)
      Agents::Workflows::RequestProductionApproval.call(workflow:)
      expect(workflow.reload.blocked_at).to be_nil
    end

    it "leaves alone a plan with no browser proof" do
      workflow = waiting_for_production(kinds: [ "test", nil ])

      expect(queue_head).to eq(workflow.ticket_id)
      Agents::Workflows::RequestProductionApproval.call(workflow:)
      expect(workflow.reload.blocked_at).to be_nil
    end

    it "reads the latest approved plan, not an older one nor one never approved" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      plan(workflow, kinds: [ "test" ])
      plan(workflow, kinds: [ "browser" ], approved: false)

      expect(described_class.owed?(workflow.reload)).to be(false)
      expect(queue_head).to eq(workflow.ticket_id)
    end

    it "stops the work already waiting when the job runs" do
      workflow = waiting_for_production(kinds: [ "browser" ])

      Agents::StagingProofJob.perform_now

      expect(workflow.reload.blocked_kind).to eq("production_approval")
    end
  end

  it "changes nothing while the switch is off" do
    workflow = waiting_for_production(kinds: [ "browser" ])

    expect(described_class.owed?(workflow)).to be(false)
    expect(queue_head).to eq(workflow.ticket_id)
    Agents::Workflows::RequestProductionApproval.call(workflow:)
    expect(workflow.reload.blocked_at).to be_nil
  end
end
