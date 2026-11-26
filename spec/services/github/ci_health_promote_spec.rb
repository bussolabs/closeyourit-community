# frozen_string_literal: true

require "rails_helper"

# CYRA-1164 — a flaky CI job opens a ticket with its figures; a second click does not open another
# while the first is open.
RSpec.describe Github::CiHealth::PromoteToTicket do
  let(:organization) { create(:organization) }
  let(:reporter) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:repository) { create(:github_repository, project:) }
  let(:job) { create(:github_ci_job, repository:, workflow_name: "ci", job_name: "test") }

  before do
    create(:membership, account: reporter, organization:, role: :owner)
    create(:ticket_status, organization:, code: "open", position: 0)
    create(:ticket_priority, organization:, code: "high", position: 0)
    %w[sha1 sha2 sha3].each_with_index do |sha, i|
      create(:github_ci_job_run, ci_job: job, conclusion: "failure", head_sha: sha, run_id: i, run_attempt: 1)
      create(:github_ci_job_run, ci_job: job, conclusion: "success", head_sha: sha, run_id: i, run_attempt: 2)
    end
  end

  def row = Github::CiHealth.call(repository:).value.sole
  def promote = described_class.call(row:, reporter:)

  it "opens a ticket in the project with the job's name, percentage, latest commits and a scenario" do
    result = promote

    expect(result).to be_ok
    ticket = result.value
    expect(ticket.project).to eq(project)
    expect(ticket.title).to include("ci / test")
    expect(ticket.description).to include("100%")
    expect(ticket.technical_analysis).to include("Flaky commits: 3 (100%)")
    expect(ticket.technical_analysis).to include("sha1", "sha2", "sha3")
    expect(ticket.scenarios.sole.step_then).to include("100%")
    expect(job.reload.ticket).to eq(ticket)
  end

  it "does not open a second ticket while the first is open" do
    first = promote.value

    second = promote

    expect(second).to be_err
    expect(job.reload.ticket).to eq(first)
    expect(Ticketing::Ticket.where(project:).count).to eq(1)
  end

  it "opens a new ticket once the first is closed" do
    first = promote.value
    first.update_column(:closed_at, Time.current)

    second = promote

    expect(second).to be_ok
    expect(second.value).not_to eq(first)
    expect(job.reload.ticket).to eq(second.value)
  end
end
