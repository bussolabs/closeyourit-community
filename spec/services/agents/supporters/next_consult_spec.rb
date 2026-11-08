# frozen_string_literal: true

require "rails_helper"

# CYRA-1197 — the stopped workflow a machine's supporter should look at next.
RSpec.describe Agents::Supporters::NextConsult do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }

  def stopped(kind: "agent_blocked", at: Time.current, project: self.project)
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    ticket.agent_workflow.tap do |w|
      w.update!(triaged_at: 1.hour.ago, planned_at: 1.hour.ago, approved_at: 1.hour.ago, autopilot_started_at: 1.hour.ago,
                blocked_at: at, blocked_phase: "autopilot", blocked_kind: kind, blocked_reason: "#{kind}: reason")
    end
  end

  it "serves the oldest stop with its reason and the last attempts" do
    newer = stopped(at: 1.minute.ago)
    older = stopped(at: 1.hour.ago)
    create(:agent_attempt, organization:, workflow: older, phase: "autopilot", status: "failed", failure_reason: "tests red")

    item = described_class.call(host:).value

    expect(item).to include(workflow_id: older.id, project_key: project.key, autonomous_max: 8)
    expect(item[:stop]).to include(kind: "agent_blocked", phase: "autopilot", reason: "agent_blocked: reason")
    expect(item[:stop][:attempts].first).to include(status: "failed", failure_reason: "tests red")
    expect(newer).to be_present
  end

  it "skips stops a person or a safety stop holds, and projects with the supporter off" do
    stopped(kind: "held_by_person")
    stopped(project: create(:project, organization:, supporter_enabled: false))

    expect(described_class.call(host:).value).to be_nil
  end

  # CYRA-1197 — a proposal whose CI stays red after its fix round: the supporter reads the failure and may send
  # it back to the agent with guidance, within the same retry limit.
  it "serves a red proposal that already had its fix round" do
    red = stopped(kind: "candidate_check")

    expect(described_class.call(host:).value).to include(workflow_id: red.id)
  end

  it "serves again a stop judged on an older record" do
    workflow = stopped
    Agents::SupporterDecision.create!(organization:, workflow:, target_type: "consult", target_id: workflow.id,
                                      target_digest: "sha256:old", outcome: "escalated", engine: "codex", risk_score: 10,
                                      evidence: {})

    expect(described_class.call(host:).value[:workflow_id]).to eq(workflow.id)
  end

  it "skips stops on tickets already concluded" do
    concluded = stopped(at: 2.hours.ago)
    concluded.ticket.update_columns(status_id: create(:ticket_status, organization:, category: :done).id)
    open = stopped(at: 1.minute.ago)

    expect(described_class.call(host:).value[:workflow_id]).to eq(open.id)
  end

  it "shows the reviewer's summary of a rejected attempt and why a lost attempt has no reason" do
    workflow = stopped(kind: "attempt_limit")
    create(:agent_attempt, organization:, workflow:, phase: "autopilot", status: "stale", created_at: 2.minutes.ago)
    create(:agent_attempt, organization:, workflow:, phase: "autopilot", status: "review_failed",
                           review: { "status" => "changes_requested", "summary" => "The backfill misses the orphan case." })

    rejected, lost = described_class.call(host:).value[:stop][:attempts]

    expect(rejected).to include(status: "review_failed", review_summary: "The backfill misses the orphan case.")
    expect(lost).to include(status: "stale", failure_reason: described_class::STALE_REASON)
  end

  it "serves only stops on projects the machine follows, even behind older ones elsewhere" do
    stopped(at: 2.hours.ago, project: create(:project, organization:, supporter_enabled: true))
    mine = stopped(at: 1.minute.ago)
    host.update!(repositories: [ project.key ])

    expect(described_class.call(host:).value[:workflow_id]).to eq(mine.id)
  end

  it "skips a stop already judged and serves the next one" do
    judged = stopped(at: 1.hour.ago)
    other = stopped(at: 1.minute.ago)
    Agents::SupporterDecision.create!(organization:, workflow: judged, target_type: "consult", target_id: judged.id,
                                      target_digest: described_class.digest(judged), outcome: "escalated",
                                      engine: "codex", risk_score: 5)

    expect(described_class.call(host:).value[:workflow_id]).to eq(other.id)
  end

  it "serves the next stop when the machine keeps failing to judge the oldest one" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    stuck = stopped(at: 1.hour.ago)
    other = stopped(at: 1.minute.ago)

    served = Array.new(Agents::Supporters::OfferLimit::MAX_OFFERS) { described_class.call(host:).value[:workflow_id] }

    expect(served).to all(eq(stuck.id))
    expect(described_class.call(host:).value[:workflow_id]).to eq(other.id)
  ensure
    Rails.cache = original
  end
end
