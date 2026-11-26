# frozen_string_literal: true

require "rails_helper"

# CYRA-1164 — the outcome of every finished CI job arrives from GitHub and is stored once.
RSpec.describe Github::Webhooks::WorkflowJob do
  let(:repository) { create(:github_repository) }

  def payload(action: "completed", **job)
    {
      "action" => action,
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id },
      "workflow_job" => {
        "id" => 111, "run_id" => 222, "run_attempt" => 2, "head_sha" => "abc123", "head_branch" => "main",
        "name" => "test", "workflow_name" => "ci", "status" => "completed", "conclusion" => "failure",
        "created_at" => "2026-11-05T10:00:00Z", "started_at" => "2026-11-05T10:01:30Z",
        "completed_at" => "2026-11-05T10:05:30Z"
      }.merge(job.transform_keys(&:to_s))
    }
  end

  it "stores workflow and job name, commit, branch, attempt, outcome and three times" do
    described_class.call(payload: payload)

    run = Github::CiJobRun.sole
    expect(run.ci_job).to have_attributes(workflow_name: "ci", job_name: "test", name: "ci / test", repository:)
    expect(run).to have_attributes(github_job_id: 111, run_id: 222, run_attempt: 2, head_sha: "abc123",
                                   head_branch: "main", conclusion: "failure")
    expect(run.queued_at).to eq(Time.utc(2026, 11, 5, 10, 0, 0))
    expect(run.started_at).to eq(Time.utc(2026, 11, 5, 10, 1, 30))
    expect(run.completed_at).to eq(Time.utc(2026, 11, 5, 10, 5, 30))
  end

  it "updates the same row when GitHub repeats a delivery" do
    described_class.call(payload: payload)
    described_class.call(payload: payload(completed_at: "2026-11-05T10:06:00Z"))

    expect(Github::CiJobRun.sole.completed_at).to eq(Time.utc(2026, 11, 5, 10, 6, 0))
    expect(Github::CiJob.count).to eq(1)
  end

  it "keeps each attempt of the same job as its own row" do
    described_class.call(payload: payload)
    described_class.call(payload: payload(id: 112, run_attempt: 3, conclusion: "success"))

    expect(Github::CiJob.sole.runs.pluck(:run_attempt)).to contain_exactly(2, 3)
  end

  it "keeps apart two workflows with a job of the same name" do
    described_class.call(payload: payload)
    described_class.call(payload: payload(id: 113, workflow_name: "deploy"))

    expect(Github::CiJob.pluck(:workflow_name)).to contain_exactly("ci", "deploy")
  end

  it "ignores a job that has not finished" do
    described_class.call(payload: payload(action: "in_progress"))

    expect(Github::CiJobRun.count).to eq(0)
  end

  it "ignores a skipped job, which never ran" do
    described_class.call(payload: payload(conclusion: "skipped"))

    expect(Github::CiJobRun.count).to eq(0)
  end

  it "ignores a repository not connected to any project" do
    described_class.call(payload: payload.merge("repository" => { "id" => 987_654 }))

    expect(Github::CiJobRun.count).to eq(0)
  end

  it "ignores the outcome when the organization is suspended" do
    repository.installation.organization.update!(suspended_at: Time.current)

    result = described_class.call(payload: payload)

    expect(result.value).to be_nil
    expect(Github::CiJobRun.count).to eq(0)
  end

  it "ignores a malformed job instead of failing" do
    described_class.call(payload: payload.merge("workflow_job" => "not an object"))
    described_class.call(payload: payload(id: [ 1 ], completed_at: "yesterday"))

    expect(Github::CiJobRun.count).to eq(0)
  end
end
