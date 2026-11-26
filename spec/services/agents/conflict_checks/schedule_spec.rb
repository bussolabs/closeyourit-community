# frozen_string_literal: true

require "rails_helper"

# CYRA-1154 — main moved: every delivered proposal still waiting on that repository gets one check.
RSpec.describe Agents::ConflictChecks::Schedule do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let(:in_review) { create(:ticket_status, :in_review, organization:) }
  let(:main_sha) { "b" * 40 }

  def waiting_ticket(number)
    ticket = create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true)
    [ ticket, delivered_waiting!(ticket:, repository:, number:) ]
  end

  def schedule(sha: main_sha, commits: [ { "message" => "Add the login page\n\nLong body" } ])
    described_class.call(repository:, main_sha: sha, commits:)
  end

  it "creates one pending check per delivered proposal, with the titles of what landed" do
    _first_ticket, first = waiting_ticket(7)
    _second_ticket, second = waiting_ticket(8)

    result = nil
    expect { result = schedule }.to have_enqueued_job(Agents::ConflictCheckJob).exactly(:once)

    checks = Agents::ConflictCheck.order(:number)
    expect(result.value).to match_array(checks.ids)
    expect(checks.map(&:delivery_candidate_id)).to eq([ first.id, second.id ])
    expect(checks.first).to have_attributes(state: "pending", main_sha:, number: 7, attempts: 0,
                                            main_titles: [ "Add the login page" ], main_commits_count: 1,
                                            next_check_at: be_present)
  end

  it "keeps one check per proposal when GitHub delivers the same push twice" do
    waiting_ticket(7)

    schedule
    second = schedule

    expect(Agents::ConflictCheck.count).to eq(1)
    expect(second.value).to be_empty
  end

  it "checks the same proposal again for a different change of main" do
    waiting_ticket(7)

    schedule
    schedule(sha: "c" * 40)

    expect(Agents::ConflictCheck.pluck(:main_sha)).to contain_exactly("b" * 40, "c" * 40)
  end

  it "leaves out the ticket the agent is still working on" do
    ticket, = waiting_ticket(7)
    ticket.agent_workflow.update!(autopilot_completed_at: nil, candidate_verified_at: nil, review_candidate_id: nil)

    expect(schedule.value).to be_empty
    expect(Agents::ConflictCheck.count).to eq(0)
  end

  it "leaves out stopped and cancelled work" do
    stopped, = waiting_ticket(7)
    cancelled, = waiting_ticket(8)
    stopped.agent_workflow.update!(blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "agent_blocked",
                                   blocked_reason: "agent_blocked: waiting for a person")
    cancelled.agent_workflow.update!(cancelled_at: Time.current)

    expect(schedule.value).to be_empty
  end

  it "leaves out a proposal GitHub already closed or merged" do
    waiting_ticket(7)
    create(:github_pull_request, repository:, number: 7, state: :merged)

    expect(schedule.value).to be_empty
  end

  it "leaves out proposals of other repositories" do
    other_project = create(:project, organization:)
    other = create(:github_repository, project: other_project, full_name: "bussolabs/other", default_branch: "main")
    ticket = create(:ticket, organization:, project: other_project, status: in_review, with_agent_workflow: true)
    delivered_waiting!(ticket:, repository: other, number: 7)

    expect(schedule.value).to be_empty
  end

  it "with three waiting tickets in two repositories, checks only the ones of the repository that moved" do
    _first, first = waiting_ticket(7)
    _second, second = waiting_ticket(8)
    other_project = create(:project, organization:)
    other = create(:github_repository, project: other_project, full_name: "bussolabs/other", default_branch: "main")
    ticket = create(:ticket, organization:, project: other_project, status: in_review, with_agent_workflow: true)
    delivered_waiting!(ticket:, repository: other, number: 7)

    schedule

    expect(Agents::ConflictCheck.pluck(:delivery_candidate_id)).to contain_exactly(first.id, second.id)
  end

  it "keeps at most 20 titles, shortened and without control characters, and counts the rest" do
    waiting_ticket(7)
    commits = Array.new(25) { |i| { "message" => "Change #{i}\e[31m #{"x" * 200}" } } + [ "not a commit" ]

    schedule(commits:)

    check = Agents::ConflictCheck.sole
    expect(check.main_titles.size).to eq(20)
    expect(check.main_titles).to all(satisfy { |title| title.length <= Agents::ConflictCheck::TITLE_LENGTH })
    expect(check.main_titles.join).not_to include("\e")
    expect(check.main_commits_count).to eq(25)
    expect(check.hidden_titles_count).to eq(5)
  end

  it "does nothing for a deleted branch or a malformed head" do
    waiting_ticket(7)

    expect(schedule(sha: "0" * 40).value).to be_empty
    expect(schedule(sha: "not-a-sha").value).to be_empty
    expect(Agents::ConflictCheck.count).to eq(0)
  end
end
