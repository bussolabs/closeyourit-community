# frozen_string_literal: true

require "rails_helper"

# CYRA-1164 — CI job outcomes are kept 90 days.
RSpec.describe Github::PruneCiRunsJob, type: :job do
  it "deletes outcomes older than 90 days and keeps the recent ones" do
    old = create(:github_ci_job_run, completed_at: 91.days.ago)
    recent = create(:github_ci_job_run, ci_job: old.ci_job, completed_at: 1.day.ago)

    described_class.perform_now

    expect(Github::CiJobRun.exists?(old.id)).to be(false)
    expect(Github::CiJobRun.exists?(recent.id)).to be(true)
  end

  it "deletes a job left with no outcomes, unless a ticket was opened from it" do
    empty = create(:github_ci_job_run, completed_at: 100.days.ago).ci_job
    with_ticket = create(:github_ci_job_run, completed_at: 100.days.ago).ci_job
    with_ticket.update_column(:ticket_id, create(:ticket, project: with_ticket.repository.project).id)

    described_class.perform_now

    expect(Github::CiJob.exists?(empty.id)).to be(false)
    expect(Github::CiJob.exists?(with_ticket.id)).to be(true)
  end

  it "is scheduled every night with the other prunings" do
    schedule = YAML.load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)

    expect(schedule.dig("production", "prune_github_ci_runs")).to include(
      "class" => "Github::PruneCiRunsJob", "queue" => "batch", "schedule" => "every day at 3am"
    )
  end
end
