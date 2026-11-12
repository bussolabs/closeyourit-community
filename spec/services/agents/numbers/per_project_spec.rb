# frozen_string_literal: true

require "rails_helper"

# The numbers of the automatic round, per project, over a window: how much it does alone, how often it
# is right the first time, how long and how much a ticket takes, and how many releases broke something.
RSpec.describe Agents::Numbers::PerProject do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:other) { create(:project, organization:) }
  let(:person) { create(:account) }
  let(:since) { 30.days.ago }

  def finished(project:, completed_at: 1.day.ago, created_at: nil, **attributes)
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    ticket.agent_workflow.tap do |flow|
      flow.update!(completed_at:, created_at: created_at || (completed_at - 2.hours), **attributes)
    end
  end

  def attempt(workflow, phase: "autopilot", cost_usd: nil)
    create(:agent_attempt, workflow:, organization:, phase:, status: :approved, cost_usd:)
  end

  def numbers(for_project = project)
    described_class.call(project_ids: [ project.id, other.id ], since:).fetch(for_project.id)
  end

  it "answers a row of zeros and no rates for a project with nothing in the window" do
    finished(project:, completed_at: 40.days.ago)

    expect(numbers).to have_attributes(completed: 0, hands_off: 0, releases: 0, failed_releases: 0,
                                       hands_off_rate: nil, attempts_per_ticket: nil, first_pass_rate: nil,
                                       lead_hours: nil, cost_per_ticket: nil, failures_per_hundred: nil)
  end

  it "counts the tickets completed in the window, per project" do
    2.times { finished(project:) }
    finished(project: other)
    finished(project:, completed_at: 31.days.ago)

    expect(numbers.completed).to eq(2)
    expect(numbers(other).completed).to eq(1)
  end

  it "counts as hands-off only the tickets no person approved at any step" do
    finished(project:)
    finished(project:, approved_by: person)
    finished(project:, autopilot_approved_by: person)
    finished(project:, closer_production_approved_by: person)

    expect(numbers.hands_off).to eq(1)
    expect(numbers.hands_off_rate).to eq(25)
  end

  it "averages the attempts over the completed tickets" do
    first = finished(project:)
    3.times { attempt(first) }
    attempt(finished(project:), phase: "triage")
    attempt(finished(project:, completed_at: 40.days.ago))

    expect(numbers.attempts_per_ticket).to eq(2.0)
  end

  it "counts a delivery as first pass when the code phase ran once" do
    once = finished(project:)
    attempt(once, phase: "triage")
    attempt(once)
    twice = finished(project:)
    2.times { attempt(twice) }

    expect(numbers.first_pass_rate).to eq(50)
  end

  it "counts the plans the supporter approved over the plans it judged" do
    flow = finished(project:)
    plan = { organization:, workflow: flow, target_type: "plan", engine: "claude", risk_score: 3 }
    Agents::SupporterDecision.create!(**plan, outcome: "approved", target_id: SecureRandom.uuid, target_digest: "a")
    Agents::SupporterDecision.create!(**plan, outcome: "escalated", target_id: SecureRandom.uuid, target_digest: "b")
    Agents::SupporterDecision.create!(**plan, outcome: "answered", target_type: "question",
                                              target_id: SecureRandom.uuid, target_digest: "c")
    Agents::SupporterDecision.create!(**plan, outcome: "approved", target_id: SecureRandom.uuid, target_digest: "d",
                                              created_at: 40.days.ago)

    expect(numbers).to have_attributes(plans_judged: 2, plans_approved: 1, plans_approved_rate: 50)
  end

  it "averages the hours from the start of the round to its end" do
    finished(project:, completed_at: 1.day.ago, created_at: 1.day.ago - 4.hours)
    finished(project:, completed_at: 2.days.ago, created_at: 2.days.ago - 8.hours)

    expect(numbers.lead_hours).to eq(6.0)
  end

  it "divides the cost of every attempt by the completed tickets" do
    first = finished(project:)
    attempt(first, cost_usd: 1.5)
    attempt(first, phase: "triage", cost_usd: 0.5)
    finished(project:)

    expect(numbers.cost_per_ticket).to eq(1.0)
  end

  it "counts a production release as failed when an error was first seen in it" do
    create(:release, project:, version: "v1.0.0")
    create(:release, project:, version: "v1.1.0")
    create(:release, project:, version: "v1.2.0", environment: "staging")
    create(:release, project:, version: "v0.9.0", created_at: 40.days.ago)
    create(:error_group, project:, first_seen_release: "v1.1.0")
    create(:error_group, project:, first_seen_release: "v1.1.0")
    create(:error_group, project: other, first_seen_release: "v1.0.0")

    expect(numbers).to have_attributes(releases: 2, failed_releases: 1, failures_per_hundred: 50)
  end
end
