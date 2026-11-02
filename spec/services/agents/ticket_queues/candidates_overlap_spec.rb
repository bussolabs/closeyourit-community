# frozen_string_literal: true

require "rails_helper"

# CYAU-299 — a ticket whose approved plan touches a file another ticket of the project is changing right now
# waits: the queue skips it and serves the next one, and it comes back by itself when that work ends.
RSpec.describe "queue and files already at work", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:host) do
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  before { versioni_uscite("v0.1.0") }

  def ready(phase, files: [], priority: 0, on: project)
    ticket = create(:ticket, :agent_workable, organization:, project: on,
                             priority: create(:ticket_priority, organization:, position: priority), with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, phase)
    plan = ticket.agent_workflow.frozen_plan
    plan&.update_columns(content: { "work_items" => [ { "title" => "Change", "files" => files.map { { "path" => it } } } ] })
    ticket
  end

  # A ticket of the project at work: a live lease and a running attempt that changed `path`.
  def at_work(path, on: project, lease_expires_at: 1.hour.from_now)
    ticket = create(:ticket, organization:, project: on, with_agent_workflow: true)
    create(:agent_lease, host:, organization:, ticket:, expires_at: lease_expires_at)
    attempt = create(:agent_attempt, workflow: ticket.agent_workflow, organization:, host:, phase: "autopilot", status: :running)
    Agents::AttemptLiveEvent.create!(organization:, attempt:, seq: 1, kind: "file_change", recorded_at: Time.current,
                                     created_at: Time.current, payload: { "path" => path, "added" => 1, "removed" => 0 })
    ticket
  end

  def served = Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:).value

  it "skips a writing ticket whose plan touches a file at work, and serves the next one" do
    at_work("app/models/ticket.rb")
    ready("autopilot", files: [ "app/models/ticket.rb" ], priority: 10)
    free = ready("autopilot", files: [ "app/models/user.rb" ], priority: 5)

    expect(served).to eq(free)
  end

  it "serves it again once the other work no longer holds its lease" do
    at_work("app/models/ticket.rb", lease_expires_at: 1.minute.ago)
    held = ready("autopilot", files: [ "app/models/ticket.rb" ])

    expect(served).to eq(held)
  end

  it "does not hold a phase that only reads" do
    at_work("app/models/ticket.rb")
    planner = ready("planner")
    planner.agent_workflow.update!(frozen_plan: nil)

    expect(served).to eq(planner)
  end

  it "ignores work on another project" do
    at_work("app/models/ticket.rb", on: create(:project, organization:))
    ticket = ready("autopilot", files: [ "app/models/ticket.rb" ])

    expect(served).to eq(ticket)
  end
end
