# frozen_string_literal: true

require "rails_helper"

# CYRA-1152 — the children of an approved split run in parallel where nothing holds them: the queue
# already skips a ticket whose prerequisites are open, so two free children go out together and the
# one that waits for both stays behind.
RSpec.describe "queue and the children of a split epic", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:epic) { create(:ticket, :epic, organization:, project:, with_agent_workflow: true) }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end

  before { versioni_uscite("v0.1.0") }

  def host_named(name)
    service_account = Accounts::Service::Create.call(organization:, name:, project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def claim(host)
    Agents::TicketQueues::ClaimNext.call(organization:, project_key: project.key, host:,
                                         params: { host_id: host.id, run_id: "run-#{SecureRandom.hex(4)}" }).value
  end

  def child(id, dependencies = [])
    { "id" => id, "title" => "Child #{id}", "description" => "Work of #{id}.", "dependencies" => dependencies,
      "scenarios" => [ { "id" => "SC-1", "title" => "Works", "given" => "a", "when" => "b", "then" => "c", "expected" => "d" } ] }
  end

  def approve_split!
    workflow = epic.agent_workflow
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current)
    Agents::Plan.create!(workflow:, attempt: create(:agent_attempt, organization:, workflow:, phase: "planner"),
                         contract_version: 2, technical_analysis: "Split", scenarios: [], definition_of_done: [ "RSpec" ],
                         notes: [], ticket_snapshot_digest: "snapshot",
                         content: { "summary" => "Split", "children" => [ child("CH-1"), child("CH-2"), child("CH-3", %w[CH-1 CH-2]) ] })
    organization.update!(cto:)
    expect(Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)).to be_ok
    # The children pass the eligibility check as every ticket does; here a person allowed them.
    epic.children.each do |created|
      created.update!(agent_eligibility: :allowed, agent_eligibility_source: :human, agent_eligibility_decided_by: cto,
                      agent_eligibility_reason: "Ordinary, reversible work.", agent_eligibility_decided_at: Time.current)
    end
  end

  it "serves the two free children together, and keeps the third until both are done" do
    approve_split!
    first_free, second_free, waiting = %w[CH-1 CH-2 CH-3].map { |id| epic.children.find_by!(title: "Child #{id}") }

    served = [ claim(host_named("Host A")), claim(host_named("Host B")) ].map(&:ticket)

    expect(served).to contain_exactly(first_free, second_free)
    expect(claim(host_named("Host C"))).to be_nil
    expect(Agents::Lease.where(ticket_id: waiting.id)).to be_empty

    done = create(:ticket_status, :done, organization:)
    [ first_free, second_free ].each { |prerequisite| prerequisite.update!(status: done) }

    expect(claim(host_named("Host D")).ticket).to eq(waiting)
  end
end
