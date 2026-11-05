# frozen_string_literal: true

require "rails_helper"

# CYRA-1155 — an epic is stalled when none of its open children moves and every one of them waits
# for someone. Each wait says who has to act and on what.
RSpec.describe Ticketing::StalledEpics::Detect do
  let(:organization) { create(:organization) }
  let(:cto) { member(role: :owner) }
  let(:project) { create(:project, organization:).tap { |record| record.update!(cto:) } }
  let(:epic) { create(:ticket, :epic, organization:, project:) }

  def member(role: :member)
    create(:account).tap { |account| create(:membership, account:, organization:, role:) }
  end

  def child(**attributes)
    create(:ticket, organization:, project:, parent: epic, **attributes)
  end

  def status(*traits)
    create(:ticket_status, *traits, organization:)
  end

  def agent_question(ticket)
    create(:ticket_question, :blocking, :from_agent, organization:, ticket:)
  end

  def awaiting_approval(ticket)
    create(:agent_workflow, ticket:, triage_requested_at: 3.hours.ago, triage_started_at: 3.hours.ago,
                            triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
  end

  def running(ticket)
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.hours.ago, triage_started_at: 1.hour.ago)
    create(:agent_attempt, workflow:, organization:, phase: "triage", status: :running, started_at: 1.hour.ago)
    workflow
  end

  def stalls = described_class.call(organization:).value

  it "flags an epic whose children all wait on an automation question, naming the question for the CTO" do
    children = Array.new(3) { child }
    questions = children.map { |ticket| agent_question(ticket) }

    stall = stalls.sole

    expect(stall.epic).to eq(epic)
    expect(stall.waits.map(&:child)).to match_array(children)
    expect(stall.waits.map(&:kind).uniq).to eq([ "question" ])
    expect(stall.waits.map(&:account).uniq).to eq([ cto ])
    expect(stall.waits.map(&:detail)).to match_array(questions.map(&:body))
  end

  it "sends a question asked by a person to whoever opened the child" do
    reporter = member
    ticket = child(reporter:)
    create(:ticket_question, :blocking, organization:, ticket:)

    expect(stalls.sole.waits.sole).to have_attributes(kind: "question", account: reporter)
  end

  it "names the plan approval and the project's technical lead" do
    ticket = child
    awaiting_approval(ticket)

    expect(stalls.sole.waits.sole).to have_attributes(child: ticket, kind: "awaiting_approval", account: cto)
  end

  it "falls back on the organization's technical lead when the project has none" do
    project.update!(cto: nil)
    organization.update!(cto: member(role: :admin))
    awaiting_approval(child)

    expect(stalls.sole.waits.sole.account).to eq(organization.cto)
  end

  it "points every child waiting on an unfinished prerequisite at that ticket's assignee" do
    assignee = member
    blocker = create(:ticket, organization:, project:, assignee:)
    children = Array.new(2) { child }
    children.each { |ticket| create(:ticket_dependency, organization:, ticket:, blocker:) }

    waits = stalls.sole.waits

    expect(waits.map(&:kind).uniq).to eq([ "dependency" ])
    expect(waits.map(&:account).uniq).to eq([ assignee ])
    expect(waits.map(&:detail).uniq).to eq([ blocker.code ])
  end

  it "stays quiet while one child is still being worked on" do
    2.times { agent_question(child) }
    running(child)

    expect(stalls).to be_empty
  end

  it "counts a child a person moved into progress by hand as being worked on" do
    agent_question(child)
    child(status: status(:in_progress))

    expect(stalls).to be_empty
  end

  it "stays quiet when a child is open but nobody waits on anything" do
    agent_question(child)
    child

    expect(stalls).to be_empty
  end

  it "stays quiet when every child is done" do
    done = status(:done)
    2.times { child(status: done) }

    expect(stalls).to be_empty
  end

  it "ignores a closed epic" do
    epic.update_column(:status_id, status(:done).id)
    agent_question(child)

    expect(stalls).to be_empty
  end

  it "keeps the fingerprint while the waits stay the same and changes it when they change" do
    ticket = child
    other = child
    agent_question(ticket)
    agent_question(other)
    before = stalls.sole.fingerprint

    expect(stalls.sole.fingerprint).to eq(before)

    awaiting_approval(other)

    expect(stalls.sole.fingerprint).not_to eq(before)
  end

  it "reads the children in bulk, whatever their number" do
    3.times { awaiting_approval(child) }
    blocker = create(:ticket, organization:, project:, assignee: member)
    3.times { create(:ticket_dependency, organization:, ticket: child, blocker:) }
    3.times { agent_question(child) }

    Prosopite.scan
    expect(stalls.sole.waits.size).to eq(9)
  ensure
    Prosopite.finish
  end
end
