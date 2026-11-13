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

  def ready_host(browser: false)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                     project_ids: [ project.id ]).value
    runtimes = [ { "name" => "claude", "present" => true } ]
    runtimes << { "name" => "tester-browser", "present" => true } if browser
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes:)
  end

  def queue_head(host: ready_host) = Agents::TicketQueues::Candidates.new(project:, host:).head_id

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

  # CYAU-329 — with the Tester on, the machine proves it in a browser: only a machine that has one takes the
  # production release, and a person decides only where no machine can.
  context "with the Tester on" do
    before { project.update!(tester: "on") }

    it "hands the release only to a machine that has the browser" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      with_browser = ready_host(browser: true)

      expect(queue_head(host: ready_host)).to be_nil
      expect(queue_head(host: with_browser)).to eq(workflow.ticket_id)
      expect(described_class.owed?(workflow)).to be(false)
      expect(described_class.host_blocked?(workflow, with_browser)).to be(false)
    end

    it "refuses the claim of a machine without the browser" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      ready_host(browser: true)

      expect(described_class.host_blocked?(workflow, ready_host)).to be(true)
    end

    def claim(workflow, host)
      token = Agents::TicketQueues::Selection.issue(ticket: workflow.ticket, host:)
      Agents::TicketQueues::Claim.call(organization:, host:, selection_token: token,
                                       params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 })
    end

    it "re-checks the browser when the release is claimed" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      with_browser = ready_host(browser: true)

      refused = claim(workflow, ready_host)

      expect(refused).to be_err
      expect(refused.error.code).to eq("R409-QUEUE-007")
      expect(refused.error.details).to include(reason: "tester_browser")
      expect(claim(workflow, with_browser)).to be_ok
    end

    it "tells the machine that takes the release to run the browser proofs first" do
      workflow = waiting_for_production(kinds: [ "browser" ])

      attempt = claim(workflow, ready_host(browser: true)).value.attempt

      expect(attempt.phase).to eq("closer_production")
      expect(described_class.machine_runs?(attempt)).to be(true)
    end

    it "does not ask the machine once a person gave the go-ahead" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      workflow.update!(closer_production_approved_at: Time.current)

      attempt = claim(workflow.reload, ready_host(browser: true)).value.attempt

      expect(described_class.machine_runs?(attempt)).to be(false)
    end

    it "does not ask the machine for a plan with no browser proof" do
      workflow = waiting_for_production(kinds: [ "test" ])

      attempt = claim(workflow, ready_host(browser: true)).value.attempt

      expect(described_class.machine_runs?(attempt)).to be(false)
    end

    it "asks a person when no machine has the browser" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      ready_host

      expect(described_class.owed?(workflow)).to be(true)
      Agents::StagingProofJob.perform_now

      expect(workflow.reload.blocked_kind).to eq("production_approval")
    end

    it "does not count a revoked machine as one that has the browser" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      ready_host(browser: true).update!(revoked_at: Time.current)

      expect(described_class.owed?(workflow)).to be(true)
    end

    it "lets any machine take it once a person gave the go-ahead" do
      workflow = waiting_for_production(kinds: [ "browser" ])
      workflow.update!(closer_production_approved_at: Time.current)
      without_browser = ready_host

      expect(queue_head(host: without_browser)).to eq(workflow.ticket_id)
      expect(described_class.host_blocked?(workflow.reload, without_browser)).to be(false)
    end

    it "leaves alone a plan with no browser proof" do
      workflow = waiting_for_production(kinds: [ "test", nil ])
      without_browser = ready_host

      expect(queue_head(host: without_browser)).to eq(workflow.ticket_id)
      expect(described_class.host_blocked?(workflow, without_browser)).to be(false)
    end

    it "still asks a person where the project wants the go-ahead on every browser proof" do
      project.update!(browser_proof_go_ahead: true)
      workflow = waiting_for_production(kinds: [ "browser" ])

      expect(described_class.owed?(workflow)).to be(true)
      expect(queue_head(host: ready_host(browser: true))).to be_nil
    end
  end

  it "does not ask for the browser while the Tester is only in a dry run" do
    project.update!(tester: "dry_run")
    workflow = waiting_for_production(kinds: [ "browser" ])
    without_browser = ready_host

    expect(queue_head(host: without_browser)).to eq(workflow.ticket_id)
    expect(described_class.host_blocked?(workflow, without_browser)).to be(false)
    expect(described_class.owed?(workflow)).to be(false)
  end

  it "changes nothing while the switch is off" do
    workflow = waiting_for_production(kinds: [ "browser" ])

    expect(described_class.owed?(workflow)).to be(false)
    expect(queue_head).to eq(workflow.ticket_id)
    Agents::Workflows::RequestProductionApproval.call(workflow:)
    expect(workflow.reload.blocked_at).to be_nil
  end
end
