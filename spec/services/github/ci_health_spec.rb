# frozen_string_literal: true

require "rails_helper"

# CYRA-1164 — the figures per CI job: failures, duration, queue wait, flakiness and its trend.
RSpec.describe Github::CiHealth do
  let(:now) { Time.zone.parse("2026-11-05 12:00") }
  let(:repository) { create(:github_repository) }
  let(:job) { create(:github_ci_job, repository:, workflow_name: "ci", job_name: "test") }

  def run(conclusion, sha:, run_id: 1, attempt: 1, at: now - 1.hour, ci_job: job, queued: 30, duration: 120)
    create(:github_ci_job_run, ci_job:, conclusion:, head_sha: sha, run_id:, run_attempt: attempt,
                               completed_at: at, started_at: at - duration, queued_at: at - duration - queued)
  end

  # A commit red on the first attempt and green on the retry of the same run.
  def retried_commit(sha, run_id:, at: now - 1.day, ci_job: job)
    run("failure", sha:, run_id:, attempt: 1, at:, ci_job:)
    run("success", sha:, run_id:, attempt: 2, at: at + 10.minutes, ci_job:)
  end

  def rows = described_class.call(repository:, now:).value
  def row_for(ci_job) = rows.find { |row| row.ci_job == ci_job }

  it "computes failures, average duration and average queue wait" do
    run("success", sha: "a", queued: 10, duration: 100)
    run("failure", sha: "b", queued: 50, duration: 300)

    row = row_for(job)
    expect(row.runs).to eq(2)
    expect(row.failures).to eq(1)
    expect(row.failure_rate).to eq(0.5)
    expect(row.avg_duration).to eq(200)
    expect(row.avg_queue).to eq(30)
  end

  it "counts a commit green only on a later attempt as flaky" do
    retried_commit("a", run_id: 10)
    run("success", sha: "b", run_id: 11)

    row = row_for(job)
    expect(row.flaky_commits).to eq(1)
    expect(row.flaky_rate).to eq(0.5)
  end

  it "marks the job flaky from three flaky commits and five percent of the commits" do
    3.times { |i| retried_commit("f#{i}", run_id: 10 + i) }
    run("success", sha: "ok", run_id: 20)

    row = row_for(job)
    expect(row).to be_flaky
    expect(row.flaky_rate).to eq(0.75)
    expect(row.recent_flaky_shas).to contain_exactly("f0", "f1", "f2")
  end

  it "does not mark the job flaky below three flaky commits" do
    2.times { |i| retried_commit("f#{i}", run_id: 10 + i) }

    expect(row_for(job)).not_to be_flaky
  end

  it "does not mark the job flaky below five percent of the commits" do
    3.times { |i| retried_commit("f#{i}", run_id: 10 + i) }
    60.times { |i| run("success", sha: "ok#{i}", run_id: 100 + i) }

    row = row_for(job)
    expect(row.flaky_commits).to eq(3)
    expect(row).not_to be_flaky
  end

  it "reads attempts by number, so a green delivered before the red still counts" do
    run("success", sha: "a", run_id: 10, attempt: 2, at: now - 2.hours)
    run("failure", sha: "a", run_id: 10, attempt: 1, at: now - 1.hour)

    expect(row_for(job).flaky_commits).to eq(1)
  end

  it "counts a new run that passes after a failed one on the same commit" do
    run("failure", sha: "a", run_id: 10, at: now - 2.hours)
    run("success", sha: "a", run_id: 11, at: now - 1.hour)

    expect(row_for(job).flaky_commits).to eq(1)
  end

  it "does not count a job that stays red on the retry as flaky" do
    run("failure", sha: "a", run_id: 10, attempt: 1)
    run("failure", sha: "a", run_id: 10, attempt: 2)

    expect(row_for(job).flaky_commits).to eq(0)
  end

  it "leaves cancelled runs out of every figure" do
    run("success", sha: "a")
    run("cancelled", sha: "b")

    expect(row_for(job).runs).to eq(1)
  end

  it "uses only the last 30 days" do
    run("failure", sha: "old", at: now - 31.days)
    run("success", sha: "new")

    expect(row_for(job).failures).to eq(0)
  end

  it "leaves out a job with outcomes only before the last 30 days" do
    run("failure", sha: "old", at: now - 40.days)

    expect(rows).to be_empty
  end

  it "marks a flaky job as worsening when it beats the 30 days before" do
    run("success", sha: "p1", run_id: 1, at: now - 40.days)
    3.times { |i| retried_commit("r#{i}", run_id: 10 + i) }

    row = row_for(job)
    expect(row.previous_flaky_rate).to eq(0)
    expect(row).to be_worsening
  end

  it "does not mark a steady flaky job as worsening" do
    3.times { |i| retried_commit("p#{i}", run_id: 1 + i, at: now - 40.days) }
    3.times { |i| retried_commit("r#{i}", run_id: 10 + i) }

    row = row_for(job)
    expect(row).to be_flaky
    expect(row.previous_flaky_rate).to eq(1)
    expect(row).not_to be_worsening
  end

  it "lists flaky jobs first" do
    steady = create(:github_ci_job, repository:, workflow_name: "ci", job_name: "lint")
    run("failure", sha: "s", ci_job: steady)
    3.times { |i| retried_commit("r#{i}", run_id: 10 + i) }

    expect(rows.map { |row| row.ci_job.name }).to eq([ "ci / test", "ci / lint" ])
  end

  it "ignores the jobs of another repository" do
    other = create(:github_ci_job, repository: create(:github_repository))
    run("failure", sha: "x", ci_job: other)

    expect(rows).to be_empty
  end
end
