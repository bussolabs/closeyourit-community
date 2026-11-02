# frozen_string_literal: true

require "rails_helper"

# CYAU-282 — the code of a concluded ticket's steps goes, and every step goes after the retention.
RSpec.describe Agents::LiveEvents::PruneJob do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:hunks) { [ { "old_start" => 1, "old_lines" => 0, "new_start" => 1, "new_lines" => 1, "lines" => [ "+x" ] } ] }
  # CYAU-299 — the line numbers stay: the project view and the queue compare them, they carry no code.
  let(:numbers_only) { [ { "old_start" => 1, "old_lines" => 0, "new_start" => 1, "new_lines" => 1, "lines" => [] } ] }

  def step(attempt, seq:, created_at: Time.current, kind: "file_change")
    payload = kind == "file_change" ? { "path" => "a.rb", "created" => false, "added" => 1, "removed" => 0, "hunks" => hunks } : { "path" => "a.rb" }
    Agents::AttemptLiveEvent.create!(organization:, attempt:, seq:, kind:, payload:, recorded_at: created_at, created_at:)
  end

  let(:project) { create(:project, organization:, automator_live_code_enabled: true) }

  def attempt_on(status_category, on: project)
    status = create(:ticket_status, organization:, category: status_category)
    ticket = create(:ticket, organization:, project: on, status:)
    workflow = create(:agent_workflow, organization:, ticket:)
    create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :running)
  end

  it "drops the code of the steps of a project that switched the code view off" do
    off = step(attempt_on(:in_progress, on: create(:project, organization:)), seq: 1)

    described_class.perform_now

    expect(off.reload.payload["hunks"]).to eq(numbers_only)
  end

  it "runs as soon as a project switches the code view off" do
    expect { project.update!(automator_live_code_enabled: false) }.to have_enqueued_job(described_class)
    expect { project.update!(name: "Other") }.not_to have_enqueued_job(described_class)
  end

  it "drops the code of a concluded ticket's steps and keeps names, counts and line numbers" do
    done = step(attempt_on(:done), seq: 1)
    open = step(attempt_on(:in_progress), seq: 1)

    described_class.perform_now

    expect(done.reload.payload).to eq("path" => "a.rb", "created" => false, "added" => 1, "removed" => 0, "hunks" => numbers_only)
    expect(open.reload.payload["hunks"]).to eq(hunks)
  end

  it "deletes the steps older than the retention" do
    attempt = attempt_on(:in_progress)
    old = step(attempt, seq: 1, created_at: (described_class::RETENTION + 1.hour).ago, kind: "file_read")
    recent = step(attempt, seq: 2, created_at: 1.day.ago, kind: "file_read")

    described_class.perform_now

    expect(Agents::AttemptLiveEvent.exists?(old.id)).to be(false)
    expect(Agents::AttemptLiveEvent.exists?(recent.id)).to be(true)
  end
end
