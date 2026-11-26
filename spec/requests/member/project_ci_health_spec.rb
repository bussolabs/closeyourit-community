# frozen_string_literal: true

require "rails_helper"

# CYRA-1164 — the CI health tab: one row per CI job, flaky jobs marked, a ticket with one click.
RSpec.describe "Member::ProjectCiHealth (CYRA-1164)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:ticket_status, organization: org, code: "open", position: 0)
    create(:ticket_priority, organization: org, code: "high", position: 0)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  # A member who sees the project but holds no permission key.
  def project_member
    create(:account).tap do |member|
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, project:, account: member)
    end
  end

  # Three commits of the test job pass only on the second attempt; a fourth passes at once.
  def flaky_job(repository, job_name: "test")
    create(:github_ci_job, repository:, workflow_name: "ci", job_name:).tap do |job|
      3.times do |i|
        create(:github_ci_job_run, ci_job: job, conclusion: "failure", head_sha: "sha#{i}", run_id: i, run_attempt: 1,
                                   completed_at: 2.days.ago)
        create(:github_ci_job_run, ci_job: job, conclusion: "success", head_sha: "sha#{i}", run_id: i, run_attempt: 2,
                                   completed_at: 2.days.ago + 1.hour)
      end
      create(:github_ci_job_run, ci_job: job, conclusion: "success", head_sha: "steady", completed_at: 1.day.ago)
    end
  end

  def row_named(name) = html.css("[data-test='ci-health-row']").find { |row| row["data-ci-job"] == name }

  describe "GET show" do
    it "invites to connect a repository when the project has none" do
      sign_in(owner)

      get member_project_ci_health_path(project)

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-test='ci-health-no-repository']")).to be_present
      expect(html.at_css("[data-test='ci-health-connect']")).to be_present
    end

    it "explains which GitHub permission and event to turn on when no outcome arrived yet" do
      create(:github_repository, project:)
      sign_in(owner)

      get member_project_ci_health_path(project)

      empty = html.at_css("[data-test='ci-health-empty']")
      expect(empty).to be_present
      expect(empty.text).to include("Actions", "Workflow job")
      expect(html.at_css("[data-test='ci-health-guide']")["href"]).to eq(member_guides_ci_health_path)
    end

    it "marks a job that passes only on the second attempt as flaky, with its percentage and the ticket button" do
      flaky_job(create(:github_repository, project:))
      sign_in(owner)

      get member_project_ci_health_path(project)

      row = row_named("ci / test")
      expect(row.at_css("[data-test='ci-health-flaky-mark']")).to be_present
      expect(row.at_css("[data-test='ci-health-flaky']").text).to include("75%")
      expect(row.at_css("[data-test='ci-health-promote']")).to be_present
    end

    it "shows the average wait in the queue of each job" do
      repository = create(:github_repository, project:)
      lint = create(:github_ci_job, repository:, workflow_name: "ci", job_name: "lint")
      [ 10.minutes, 5.minutes ].each_with_index do |wait, i|
        finished = (i + 1).hours.ago
        create(:github_ci_job_run, ci_job: lint, completed_at: finished, started_at: finished - 90.seconds,
                                   queued_at: finished - 90.seconds - wait)
      end
      sign_in(owner)

      get member_project_ci_health_path(project)

      expect(row_named("ci / lint").at_css("[data-test='ci-health-queue']").text).to include("7 min 30 s")
    end

    it "shows failures, duration, wait and flakiness for every job" do
      repository = create(:github_repository, project:)
      flaky_job(repository)
      lint = create(:github_ci_job, repository:, workflow_name: "ci", job_name: "lint")
      create(:github_ci_job_run, ci_job: lint, conclusion: "failure", completed_at: 1.hour.ago,
                                 started_at: 1.hour.ago - 90.seconds, queued_at: 1.hour.ago - 100.seconds)
      sign_in(owner)

      get member_project_ci_health_path(project)

      expect(html.css("[data-test='ci-health-row']").size).to eq(2)
      lint_row = row_named("ci / lint")
      expect(lint_row.at_css("[data-test='ci-health-failures']").text).to include("1 · 100%")
      expect(lint_row.at_css("[data-test='ci-health-duration']").text).to include("1 min 30 s")
      expect(lint_row.at_css("[data-test='ci-health-queue']").text).to include("10 s")
      expect(lint_row.at_css("[data-test='ci-health-flaky']").text).to include("0%")
      expect(lint_row.at_css("[data-test='ci-health-flaky-mark']")).to be_nil
      expect(lint_row.at_css("[data-test='ci-health-promote']")).to be_nil
      expect(row_named("ci / test").at_css("[data-test='ci-health-failures']").text).to include("3 · 43%")
    end

    it "shows the page but not the ticket button to whoever cannot open tickets from CI jobs" do
      flaky_job(create(:github_repository, project:))
      sign_in(project_member)

      get member_project_ci_health_path(project)

      expect(response).to have_http_status(:ok)
      row = row_named("ci / test")
      expect(row.at_css("[data-test='ci-health-flaky-mark']")).to be_present
      expect(row.at_css("[data-test='ci-health-promote']")).to be_nil
    end

    it "is reachable from the project tabs" do
      sign_in(owner)

      get member_project_path(project)

      expect(html.at_css("[data-test='project-ci-health-link']")).to be_present
    end

    it "does not show the project of another organization" do
      other = create(:project)
      sign_in(owner)

      get member_project_ci_health_path(other)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST promote" do
    it "opens one ticket with the job's name and percentage, and a second click leads to it" do
      job = flaky_job(create(:github_repository, project:))
      sign_in(owner)

      post promote_member_project_ci_health_job_path(project, job)
      ticket = job.reload.ticket
      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.title).to include("ci / test")
      expect(ticket.description).to include("75%")

      expect { post promote_member_project_ci_health_job_path(project, job) }
        .not_to change(Ticketing::Ticket, :count)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "refuses whoever cannot open tickets from CI jobs" do
      job = flaky_job(create(:github_repository, project:))
      sign_in(project_member)

      expect { post promote_member_project_ci_health_job_path(project, job) }
        .not_to change(Ticketing::Ticket, :count)
      expect(job.reload.ticket).to be_nil
    end

    it "refuses a job that is not flaky" do
      repository = create(:github_repository, project:)
      job = create(:github_ci_job, repository:)
      create(:github_ci_job_run, ci_job: job, conclusion: "success")
      sign_in(owner)

      expect { post promote_member_project_ci_health_job_path(project, job) }
        .not_to change(Ticketing::Ticket, :count)
      expect(response).to redirect_to(member_project_ci_health_path(project))
    end

    it "does not reach the job of another project" do
      job = flaky_job(create(:github_repository))
      create(:github_repository, project:)
      sign_in(owner)

      post promote_member_project_ci_health_job_path(project, job)

      expect(response).to have_http_status(:not_found)
    end
  end
end
