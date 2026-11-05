# frozen_string_literal: true

require "rails_helper"

# CYRA-1165 — the Tests tab of a project: the tests the CI reported, the flaky ones, the known
# failures, and the history of one test run by run. Who can edit the project marks known failures.
RSpec.describe "Member::ProjectTests", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) } }
  let(:project) { create(:project, organization: org) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def viewer
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role: :member)
      create(:project_membership, account:, project:)
    end
  end

  def html = Capybara.string(response.body)

  def run_with(test_case, status, ran_at: 1.hour.ago, version: "v2.0.0", sha: "a" * 40, known_failure: false)
    run = create(:test_run, project:, version:, sha:, ran_at:)
    create(:test_result, test_run: run, test_case:, status:, known_failure:)
    run
  end

  describe "GET index" do
    # Scenario 7.
    it "explains how to connect the CI when the project never sent results" do
      sign_in(owner)

      get member_project_tests_path(project)

      expect(response).to have_http_status(:ok)
      expect(html).to have_css("[data-test='tests-empty']")
      expect(html).to have_css("[data-test='tests-empty-guide'][href='#{member_guides_tests_path}']")
      expect(html).to have_css("[data-test='project-tab-more-menu'] [data-test='project-tests-link']", visible: :all)
    end

    it "lists the tests with their last outcome, the flaky mark and the counts" do
      stable = create(:test_case, project:, name: "User is stable", last_status: "passed")
      create(:test_case, project:, name: "User flips", last_status: "failed", flaky_at: 2.hours.ago)
      create(:known_failure, test_case: create(:test_case, project:, name: "User waits for a fix", last_status: "failed"))
      run_with(stable, "passed")
      sign_in(owner)

      get member_project_tests_path(project)

      expect(html).to have_css("[data-test='tests-row']", count: 3)
      expect(html).to have_css("[data-test='tests-row-flaky']", count: 1)
      expect(html).to have_css("[data-test='tests-count-flaky']", text: "1")
      expect(html).to have_css("[data-test='tests-count-failing']", text: "2")
      expect(html).to have_css("[data-test='tests-count-known']", text: "1")
      expect(html).to have_css("[data-test='tests-last-run']", text: "v2.0.0")
    end

    # One request per example: Prosopite reads the same request repeated in one example as an N+1.
    { "flaky" => "User flips", "failing" => "User waits for a fix", "known" => "User waits for a fix" }.each do |filter, name|
      it "filters by #{filter}" do
        create(:test_case, project:, name: "User is stable", last_status: "passed")
        create(:test_case, project:, name: "User flips", last_status: "passed", flaky_at: 2.hours.ago)
        create(:known_failure, test_case: create(:test_case, project:, name: "User waits for a fix", last_status: "failed"))
        sign_in(owner)

        get member_project_tests_path(project, filter:)

        expect(html).to have_css("[data-test='tests-row']", count: 1)
        expect(html).to have_css("[data-test='tests-row-link']", text: name)
      end
    end

    it "answers 404 for a project out of sight" do
      sign_in(owner)

      get member_project_tests_path(create(:project, organization: create(:organization)))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    # Scenario 1 / DOD-2: the history, run by run, with version and commit.
    it "shows the history of the test run by run, with version and commit" do
      test_case = create(:test_case, project:, name: "User flips", last_status: "failed", flaky_at: 1.hour.ago)
      run_with(test_case, "passed", ran_at: 2.hours.ago, version: "v2.0.0", sha: "b" * 40)
      run_with(test_case, "failed", ran_at: 1.hour.ago, version: "v2.0.1", sha: "c" * 40)
      sign_in(owner)

      get member_project_test_path(project, test_case)

      expect(response).to have_http_status(:ok)
      rows = html.all("[data-test='test-history-row']")
      expect(rows.size).to eq(2)
      expect(rows.first.text).to include("v2.0.1", "ccccccc")
      expect(rows.last.text).to include("v2.0.0", "bbbbbbb")
      expect(html).to have_css("[data-test='test-flaky']")
    end

    # Scenario 3: a failure under a valid known failure reads «known», next to its ticket.
    it "shows a known failure in the history and its ticket" do
      test_case = create(:test_case, project:, last_status: "failed")
      ticket = create(:ticket, project:)
      create(:known_failure, test_case:, ticket:, marked_by: owner)
      run_with(test_case, "failed", known_failure: true)
      sign_in(owner)

      get member_project_test_path(project, test_case)

      expect(html).to have_css("[data-test='test-history-status']", text: I18n.t("member.project_tests.status.known"))
      expect(html).to have_css("[data-test='test-known-failure-ticket']", text: ticket.code)
    end

    it "shows the form to who can edit the project" do
      test_case = create(:test_case, project:, last_status: "failed")
      sign_in(owner)

      get member_project_test_path(project, test_case)

      expect(html).to have_css("[data-test='test-known-failure-form']")
    end

    # Scenario 6.
    it "shows history and flaky mark but no command to who only sees the project" do
      test_case = create(:test_case, project:, last_status: "failed", flaky_at: 1.hour.ago)
      create(:known_failure, test_case:)
      run_with(test_case, "failed")
      sign_in(viewer)

      get member_project_test_path(project, test_case)

      expect(response).to have_http_status(:ok)
      expect(html).to have_css("[data-test='test-history-row']")
      expect(html).to have_css("[data-test='test-flaky']")
      expect(html).to have_no_css("[data-test='test-known-failure-form']")
      expect(html).to have_no_css("[data-test='test-known-failure-clear']")
    end

    it "answers 404 for a test of another project (anti-BOLA)" do
      foreign = create(:test_case, project: create(:project, organization: org))
      sign_in(owner)

      get member_project_test_path(project, foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "known failures" do
    let(:test_case) { create(:test_case, project:, last_status: "failed") }
    let(:ticket) { create(:ticket, project:) }

    def mark(params)
      post member_project_test_known_failure_path(project, test_case), params:
    end

    # DOD-4: tied to a ticket, with an expiry, marked by a person.
    it "marks the test as a known failure with ticket, expiry and who did it" do
      sign_in(owner)

      mark(ticket: ticket.code, expires_on: 10.days.from_now.to_date.iso8601)

      expect(response).to redirect_to(member_project_test_path(project, test_case))
      known = test_case.reload.known_failure
      expect(known.ticket).to eq(ticket)
      expect(known.expires_on).to eq(10.days.from_now.to_date)
      expect(known.marked_by).to eq(owner)
    end

    it "accepts the ticket number alone and replaces an earlier mark" do
      create(:known_failure, test_case:, expires_on: 2.days.from_now.to_date)
      sign_in(owner)

      mark(ticket: ticket.number.to_s, expires_on: 20.days.from_now.to_date.iso8601)

      expect(Projects::KnownFailure.where(test_case:).sole.expires_on).to eq(20.days.from_now.to_date)
    end

    it "refuses a ticket of another project, an expiry in the past or too far" do
      foreign = create(:ticket, project: create(:project, organization: org))
      sign_in(owner)

      mark(ticket: foreign.code, expires_on: 10.days.from_now.to_date.iso8601)
      mark(ticket: ticket.code, expires_on: 1.day.ago.to_date.iso8601)
      mark(ticket: ticket.code, expires_on: 400.days.from_now.to_date.iso8601)

      expect(flash[:alert]).to be_present
      expect(test_case.reload.known_failure).to be_nil
    end

    it "clears the mark" do
      create(:known_failure, test_case:)
      sign_in(owner)

      delete member_project_test_known_failure_path(project, test_case)

      expect(response).to redirect_to(member_project_test_path(project, test_case))
      expect(test_case.reload.known_failure).to be_nil
    end

    it "refuses who sees the project without projects.edit" do
      sign_in(viewer)

      mark(ticket: ticket.code, expires_on: 10.days.from_now.to_date.iso8601)

      expect(response).to redirect_to(root_path)
      expect(test_case.reload.known_failure).to be_nil
    end
  end
end
