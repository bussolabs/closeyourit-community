# frozen_string_literal: true

require "rails_helper"

# CYRA-1165 — the CI sends the outcome of every test of a run, tied to version and commit. Every run
# is kept, each test builds a history, flaky tests and known failures are recognised on arrival.
RSpec.describe "Api::V1::TestRuns", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:token) { issue_token }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:path) { "/api/v1/projects/#{project.id}/test_runs" }
  let(:sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }

  def issue_token(scopes: nil)
    options = { project:, name: "CI", host: "bugs.example.com", environment: }
    options[:scopes] = scopes if scopes
    Projects::Tokens::Issue.call(**options).value[:secret]
  end

  # A run time some hours ago, inside the flaky lookback whatever day the suite runs.
  def at(hours_ago)
    hours_ago.hours.ago.utc.change(usec: 0).iso8601
  end

  def report(tests, **overrides)
    { version: "v1.4.0", sha: sha, branch: "main", ran_at: at(3), tests: tests }.merge(overrides)
  end

  def test_entry(name, status, file: "spec/models/user_spec.rb", **extra)
    { file: file, name: name, status: status }.merge(extra)
  end

  def send_report(body, with: headers)
    post path, headers: with, as: :json, params: body
  end

  describe "POST /api/v1/projects/:id/test_runs" do
    it "records the run, its totals and one result per test, tied to the release with the same version" do
      release = create(:release, project:, version: "v1.4.0")

      send_report(report([ test_entry("User validates the email", "passed", duration_ms: 12),
                           test_entry("User sends the welcome mail", "failed", duration_ms: 340, message: "expected 1, got 0"),
                           test_entry("User exports", "skipped") ]))

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data).to include("tests_count" => 3, "passed_count" => 1, "failed_count" => 1, "skipped_count" => 1,
                              "known_failed_count" => 0, "new_failed_count" => 1, "sha" => sha, "version" => "v1.4.0")
      expect(data["new_failures"]).to eq([ { "file" => "spec/models/user_spec.rb", "name" => "User sends the welcome mail" } ])
      run = project.test_runs.sole
      expect(run.release).to eq(release)
      expect(run.results.count).to eq(3)
      failed = project.test_cases.find_by(name: "User sends the welcome mail")
      expect(failed.last_status).to eq("failed")
      expect(failed.results.sole.message).to eq("expected 1, got 0")
    end

    it "accumulates the history of a test across runs, by file and full name" do
      send_report(report([ test_entry("User validates the email", "passed") ], sha: "a" * 40))
      send_report(report([ test_entry("User validates the email", "failed") ], sha: "b" * 40, ran_at: at(2)))

      test_case = project.test_cases.sole
      expect(test_case.results.count).to eq(2)
      expect(test_case.last_status).to eq("failed")
    end

    it "keeps the last status of the newest run when an older run arrives late" do
      send_report(report([ test_entry("User validates the email", "passed") ], ran_at: at(1)))
      send_report(report([ test_entry("User validates the email", "failed") ], sha: "c" * 40, ran_at: at(5)))

      expect(project.test_cases.sole.last_status).to eq("passed")
    end

    # Scenario 1 / DOD-3.
    it "marks as flaky a test that passed and failed on the same commit" do
      send_report(report([ test_entry("User validates the email", "passed"), test_entry("User is stable", "passed") ]))
      expect(project.test_cases.flaky).to be_empty

      second_run_at = at(2)
      send_report(report([ test_entry("User validates the email", "failed"), test_entry("User is stable", "passed") ],
                         ran_at: second_run_at))

      flaky = project.test_cases.flaky.sole
      expect(flaky.name).to eq("User validates the email")
      expect(flaky.flaky_at).to eq(Time.iso8601(second_run_at))
      expect(flaky.flaky_sha).to eq(sha)
    end

    it "does not call flaky a test that changed outcome across different commits" do
      send_report(report([ test_entry("User validates the email", "passed") ], sha: "d" * 40))
      send_report(report([ test_entry("User validates the email", "failed") ], sha: "e" * 40))

      expect(project.test_cases.flaky).to be_empty
    end

    # Scenario 3 / DOD-4.
    it "counts as known a failure covered by a known failure still valid" do
      test_case = create(:test_case, project:, name: "User sends the welcome mail")
      create(:known_failure, test_case:, expires_on: 7.days.from_now.to_date)

      send_report(report([ test_entry("User sends the welcome mail", "failed") ]))

      data = response.parsed_body["data"]
      expect(data).to include("failed_count" => 1, "known_failed_count" => 1, "new_failed_count" => 0, "new_failures" => [])
      expect(test_case.results.sole.known_failure).to be(true)
    end

    # Scenario 2 / DOD-5.
    it "counts as new a failure whose known failure has expired" do
      test_case = create(:test_case, project:, name: "User sends the welcome mail")
      known = create(:known_failure, test_case:)
      known.update_columns(expires_on: 1.day.ago.to_date)

      send_report(report([ test_entry("User sends the welcome mail", "failed") ]))

      expect(response.parsed_body["data"]).to include("known_failed_count" => 0, "new_failed_count" => 1)
      expect(test_case.results.sole.known_failure).to be(false)
    end

    it "keeps the worst outcome when a report names the same test twice" do
      send_report(report([ test_entry("User retries", "failed"), test_entry("User retries", "passed") ]))

      expect(response.parsed_body["data"]).to include("tests_count" => 1, "failed_count" => 1)
    end

    it "reads the common status words of the standard reports" do
      send_report(report([ test_entry("a", "error"), test_entry("b", "success"), test_entry("c", "pending") ]))

      expect(response.parsed_body["data"]).to include("failed_count" => 1, "passed_count" => 1, "skipped_count" => 1)
    end

    it "shortens a long error message" do
      send_report(report([ test_entry("User breaks", "failed", message: "x" * 5_000) ]))

      expect(Projects::TestResult.sole.message.length).to eq(Projects::TestResult::MESSAGE_LIMIT)
    end

    it "refuses a report without the commit, with its own code" do
      send_report(report([ test_entry("a", "passed") ], sha: ""))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TESTRUN-001")
    end

    it "refuses a report without tests" do
      send_report(report([]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TESTRUN-002")
    end

    it "refuses the whole report when one test is malformed, writing nothing" do
      send_report(report([ test_entry("a", "passed"), test_entry("b", "exploded") ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TESTRUN-004")
      expect(response.parsed_body.dig("error", "message")).to include("tests[1]")
      expect(Projects::TestRun.count).to eq(0)
      expect(Projects::TestCase.count).to eq(0)
    end

    it "refuses a report over the number of tests, writing nothing" do
      stub_const("Projects::TestRun::MAX_TESTS", 2)

      send_report(report([ test_entry("a", "passed"), test_entry("b", "passed"), test_entry("c", "passed") ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TESTRUN-003")
      expect(Projects::TestRun.count).to eq(0)
    end

    # Scenario 4 / DOD-6.
    it "refuses a report over the weight cap with a clear message, writing nothing" do
      stub_const("Projects::TestRun::MAX_PAYLOAD_BYTES", 1.kilobyte)

      send_report(report([ test_entry("a" * 2.kilobytes, "passed") ]))

      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-TESTRUN-001")
      expect(response.parsed_body.dig("error", "message")).to include("MB")
      expect(Projects::TestRun.count).to eq(0)
    end

    # Scenario 5.
    it "refuses a read-only key, writing nothing" do
      read_only = issue_token(scopes: [ "read" ])

      send_report(report([ test_entry("a", "passed") ]), with: { "Authorization" => "Bearer #{read_only}" })

      expect(response).to have_http_status(:forbidden)
      expect(Projects::TestRun.count).to eq(0)
    end

    it "refuses a call without a key" do
      post path, as: :json, params: report([ test_entry("a", "passed") ])

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses the key of another project (anti-BOLA)" do
      other = create(:project, organization:)

      post "/api/v1/projects/#{other.id}/test_runs", headers:, as: :json, params: report([ test_entry("a", "passed") ])

      expect(response).to have_http_status(:not_found)
      expect(Projects::TestRun.count).to eq(0)
    end
  end
end
