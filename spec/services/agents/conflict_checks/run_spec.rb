# frozen_string_literal: true

require "rails_helper"

# CYRA-1154 — after main moved, GitHub says whether the delivered proposal still merges. A conflict
# sends the work back to the agent once; an answer not ready yet is asked again with growing waits.
RSpec.describe Agents::ConflictChecks::Run do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let!(:in_review) { create(:ticket_status, :in_review, organization:) }
  let!(:working) { create(:ticket_status, :in_progress, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let!(:candidate) { delivered_waiting!(ticket:, repository:) }
  let(:check) do
    create(:agent_conflict_check, delivery_candidate: candidate, organization:, main_sha: "b" * 40,
                                  main_titles: [ "Rename the login form" ], main_commits_count: 1)
  end
  let(:now) { Time.current.change(usec: 0) }

  def client_answering(mergeable, state: "OPEN")
    instance_double(Github::Client).tap do |client|
      allow(client).to receive(:pull_request_state).and_return(merge_state(mergeable, state:))
    end
  end

  def run(client, at: now) = described_class.call(check: check.reload, client:, now: at)

  def notices = ticket.events.where(action: "pull_request_conflict")

  it "starts from a delivery waiting for a person" do
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  it "closes the check and leaves the ticket in review when the proposal still merges" do
    run(client_answering("MERGEABLE"))

    expect(check.reload).to have_attributes(state: "clean", next_check_at: nil)
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
    expect(ticket.reload.status).to eq(in_review)
    expect(notices).to be_empty
  end

  it "sends the work back to the agent in conflict resolution mode, with one notice" do
    run(client_answering("CONFLICTING"))

    expect(check.reload).to have_attributes(state: "sent_back", handled_at: be_present, next_check_at: nil)
    expect(workflow.reload).to have_attributes(autopilot_started_at: nil, autopilot_completed_at: nil,
                                               candidate_verified_at: nil, review_candidate_id: nil,
                                               conflict_resolution_requested_at: be_present)
    expect(workflow.ready_execution_phase).to eq("autopilot")
    expect(ticket.reload.status).to have_attributes(review_gate: false, category: "in_progress")
    expect(notices.sole.data).to include("number" => 7, "main_sha" => "b" * 12)
    expect(notices.sole.actor_name).to eq(I18n.t("member.tickets.activity.system.github"))
  end

  it "takes back an approval given to work not yet in release" do
    workflow.update!(autopilot_approved_at: 10.minutes.ago)
    expect(workflow.reload.phase).to eq("closer_staging_queued")

    run(client_answering("CONFLICTING"))

    expect(workflow.reload).to have_attributes(autopilot_approved_at: nil, autopilot_approved_by_id: nil,
                                               conflict_resolution_requested_at: be_present)
    expect(notices.count).to eq(1)
  end

  it "asks again with growing waits while GitHub has not computed the answer, five reads in all" do
    client = client_answering("UNKNOWN")
    waits = Array.new(described_class::MAX_READS - 1) do |index|
      run(client, at: now + index.minutes)
      check.reload.next_check_at - (now + index.minutes)
    end

    expect(waits).to eq([ 30, 60, 120, 240 ])
    expect(check.reload).to have_attributes(state: "pending", attempts: 4, last_error_code: "mergeable_unknown")
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")

    run(client, at: now + 10.minutes)

    expect(client).to have_received(:pull_request_state).exactly(5).times
    expect(check.reload).to have_attributes(state: "gave_up", attempts: 5, next_check_at: nil)
    expect(ticket.reload.status).to eq(in_review)
    expect(notices).to be_empty
  end

  it "decides once GitHub answers, after two reads that were not ready" do
    client = instance_double(Github::Client)
    allow(client).to receive(:pull_request_state)
      .and_return(merge_state("UNKNOWN"), merge_state("UNKNOWN"), merge_state("CONFLICTING"))

    run(client)
    first_wait = check.reload.next_check_at - now
    run(client, at: check.next_check_at)
    second_wait = check.reload.next_check_at - (now + first_wait)
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")

    run(client, at: check.next_check_at)

    expect([ first_wait, second_wait ]).to eq([ 30, 60 ])
    expect(check.reload).to have_attributes(state: "sent_back", attempts: 2)
    expect(workflow.reload.ready_execution_phase).to eq("autopilot")
  end

  it "gives up at the fifth read without an answer, leaves the ticket where it is and logs it" do
    check.update!(attempts: described_class::MAX_READS - 1)
    allow(Rails.logger).to receive(:warn)

    run(client_answering("UNKNOWN"))

    expect(check.reload).to have_attributes(state: "gave_up", attempts: 5, next_check_at: nil)
    expect(Rails.logger).to have_received(:warn).with(/gave up after 5 reads/)
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
    expect(ticket.reload.status).to eq(in_review)
  end

  it "counts an unreachable GitHub as an empty read" do
    client = instance_double(Github::Client)
    allow(client).to receive(:pull_request_state)
      .and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001", status: :bad_gateway))

    run(client)

    expect(check.reload).to have_attributes(state: "pending", attempts: 1, last_error_code: "R502-GITHUB-001")
  end

  it "comes back no earlier than the rate limit asks" do
    client = instance_double(Github::Client)
    allow(client).to receive(:pull_request_state)
      .and_raise(Github::Client::Error.new("limit", code: "R502-GITHUB-001", retry_after: 600))

    run(client)

    expect(check.reload.next_check_at).to eq(now + 600.seconds)
  end

  it "closes the check when the proposal is gone or no longer open" do
    run(client_answering("CONFLICTING", state: "MERGED"))

    expect(check.reload).to have_attributes(state: "skipped", last_error_code: "pull_request_not_open")
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  it "closes the check when the proposal no longer targets main" do
    client = instance_double(Github::Client)
    allow(client).to receive(:pull_request_state)
      .and_return(merge_state("CONFLICTING").merge(base_ref: "release"))

    run(client)

    expect(check.reload).to have_attributes(state: "skipped", last_error_code: "pull_request_not_on_main")
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  it "leaves alone a delivery a person refused, without calling GitHub" do
    Ticketing::Event.create!(organization:, ticket:, action: "review_rejected", actor_name: "Ada",
                             data: { "mode" => "hold" })
    client = client_answering("CONFLICTING")

    run(client)

    expect(client).not_to have_received(:pull_request_state)
    expect(check.reload).to have_attributes(state: "skipped", last_error_code: "held_by_person")
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  it "calls GitHub for no repository that stopped syncing or whose organization is suspended" do
    client = client_answering("CONFLICTING")
    repository.update!(sync_enabled: false)
    run(client)
    expect(check.reload).to have_attributes(state: "skipped", last_error_code: "sync_disabled")

    repository.update!(sync_enabled: true)
    organization.update!(suspended_at: Time.current)
    other = create(:agent_conflict_check, delivery_candidate: candidate, organization:, main_sha: "c" * 40)
    described_class.call(check: other, client:, now:)

    expect(other.reload).to have_attributes(state: "skipped", last_error_code: "organization_suspended")
    expect(client).not_to have_received(:pull_request_state)
  end

  # The agent resolved and delivered again: the delivery clears the request (Effects::Autopilot), the
  # verification points the workflow at the same proposal, and a person is waiting on it once more.
  def redeliver!
    workflow.reload.update!(autopilot_started_at: 20.minutes.ago, autopilot_completed_at: 10.minutes.ago,
                            conflict_resolution_requested_at: nil, candidate_verified_at: 5.minutes.ago,
                            review_candidate_id: candidate.id)
    ticket.reload.update!(status: in_review)
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end

  it "stops the work with the reason when this proposal already had its resolution round" do
    run(client_answering("CONFLICTING"))
    expect(check.reload.state).to eq("sent_back")
    redeliver!
    again = create(:agent_conflict_check, delivery_candidate: candidate, organization:, main_sha: "c" * 40)

    described_class.call(check: again, client: client_answering("CONFLICTING"), now: now + 1.hour)

    expect(again.reload).to have_attributes(state: "stopped", handled_at: be_present)
    expect(workflow.reload).to have_attributes(blocked_phase: "autopilot", blocked_kind: "candidate_check",
                                               autopilot_completed_at: be_present)
    expect(workflow.blocked_reason).to include("merge_conflict on bussolabs/closeyourit-rails#7", "c" * 12)
    expect(ticket.reload.status).to eq(in_review)
    expect(notices.count).to eq(1)
  end

  it "stops the work when another path asked for the round and it is not delivered yet" do
    workflow.update!(conflict_resolution_requested_at: 1.hour.ago)

    run(client_answering("CONFLICTING"))

    expect(check.reload.state).to eq("stopped")
    expect(workflow.reload.blocked_reason).to include("merge_conflict")
  end

  # The six-hour recheck, the first verification or the agent stopping on a conflict at the staging release
  # gave the round; its delivery cleared the request. No check row remembers it: the workflow does.
  it "stops the work when another path gave the round and its delivery already came back" do
    Agents::Candidates::RecheckWaiting.call(client: client_answering("CONFLICTING"), now: 2.hours.ago)
    expect(workflow.reload.conflict_resolution_requested_at).to be_present
    redeliver!
    expect(Agents::ConflictCheck.where(workflow_id: workflow.id)).to be_empty

    run(client_answering("CONFLICTING"))

    expect(check.reload.state).to eq("stopped")
    expect(workflow.reload).to have_attributes(blocked_phase: "autopilot", conflict_resolution_used_at: be_present)
    expect(workflow.blocked_reason).to include("merge_conflict on bussolabs/closeyourit-rails#7")
    expect(notices).to be_empty
  end

  it "lets a late MERGEABLE read leave the send back alone" do
    stale = Agents::ConflictCheck.includes(:workflow, delivery_candidate: { repository: :installation }).find(check.id)
    stale.workflow.ticket

    run(client_answering("CONFLICTING"))
    described_class.call(check: stale, client: client_answering("MERGEABLE"), now: now + 2.seconds)

    expect(check.reload).to have_attributes(state: "sent_back", main_titles: [ "Rename the login form" ])
    expect(workflow.reload.conflict_resolution_requested_at).to be_present
    expect(notices.count).to eq(1)
  end

  it "counts two overlapping empty reads of the same row as one" do
    stale = Agents::ConflictCheck.includes(:workflow, delivery_candidate: { repository: :installation }).find(check.id)
    stale.workflow.ticket
    client = client_answering("UNKNOWN")

    run(client)
    described_class.call(check: stale, client:, now: now + 1.second)

    expect(check.reload).to have_attributes(state: "pending", attempts: 1, next_check_at: now + 30.seconds)
  end

  it "folds the other pending pushes of the same delivery into the one send back" do
    check.update!(created_at: 2.minutes.ago)
    later = create(:agent_conflict_check, delivery_candidate: candidate, organization:, main_sha: "c" * 40,
                                          main_titles: [ "Move the header" ], main_commits_count: 2)

    run(client_answering("CONFLICTING"))

    expect(later.reload).to have_attributes(state: "skipped", last_error_code: "superseded")
    expect(check.reload).to have_attributes(state: "sent_back", main_titles: [ "Rename the login form", "Move the header" ],
                                            main_commits_count: 3)
  end

  it "does not call GitHub for work that already moved on" do
    workflow.update!(**Agents::Workflow.autopilot_rework)
    client = instance_double(Github::Client)
    allow(client).to receive(:pull_request_state)

    run(client)

    expect(client).not_to have_received(:pull_request_state)
    expect(check.reload).to have_attributes(state: "skipped", last_error_code: "no_longer_waiting")
  end

  it "sends the work back once when two changes of main land a few seconds apart" do
    second = create(:agent_conflict_check, delivery_candidate: candidate, organization:, main_sha: "c" * 40)
    client = client_answering("CONFLICTING")

    run(client)
    described_class.call(check: second, client:, now: now + 5.seconds)

    expect(second.reload).to have_attributes(state: "skipped", last_error_code: "superseded")
    expect(notices.count).to eq(1)
    expect(ticket.events.where(action: "status_changed").count).to eq(1)
  end
end
