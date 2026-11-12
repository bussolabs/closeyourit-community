# frozen_string_literal: true

require "rails_helper"

# CYRA-1291 — the risk of a delivery is read on the files it really changed, not on the files the plan named.
RSpec.describe Agents::Candidates::ScopeCheck do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def check(paths:, declared: [], truncated: false)
    described_class.call(paths:, declared_paths: declared, organization:, project:, truncated:)
  end

  it "clears a delivery that only changes ordinary files named by the plan" do
    verdict = check(paths: %w[app/models/user.rb spec/models/user_spec.rb],
                    declared: %w[app/models/user.rb spec/models/user_spec.rb])

    expect(verdict).to have_attributes(review?: false, reasons: [], outside_plan: [])
  end

  it "sends to a person a delivery that changes a workflow file the plan never named" do
    verdict = check(paths: %w[app/models/user.rb .github/workflows/ci.yml], declared: %w[app/models/user.rb])

    expect(verdict).to be_review
    expect(verdict.reasons).to eq(%w[sensitive_path_undeclared])
    expect(verdict.sensitive).to eq(%w[.github/workflows/ci.yml])
  end

  it "sends to a person a delivery that changes an access file the plan never named" do
    verdict = check(paths: %w[app/controllers/auth/sessions_controller.rb], declared: [])

    expect(verdict.reasons).to include("sensitive_path_undeclared")
  end

  it "lets through a sensitive file the approved plan named" do
    verdict = check(paths: %w[.github/workflows/ci.yml], declared: %w[.github/workflows/ci.yml])

    expect(verdict).not_to be_review
  end

  it "does not accept a different file of the same sensitive folder as named" do
    verdict = check(paths: %w[.github/workflows/release.yml], declared: %w[.github/workflows/ci.yml])

    expect(verdict.reasons).to eq(%w[sensitive_path_undeclared])
  end

  it "sends to a person a deploy file the plan never named" do
    verdict = check(paths: %w[Dockerfile], declared: [])

    expect(verdict.reasons).to eq(%w[sensitive_path_undeclared])
  end

  it "always sends a data change to a person, even when the plan named it" do
    migration = "db/migrate/20261112090000_add_notes_to_orders.rb"
    verdict = check(paths: [ migration, "db/schema.rb" ], declared: [ migration, "db/schema.rb" ])

    expect(verdict.reasons).to eq(%w[data_change])
    expect(verdict.data).to eq([ migration, "db/schema.rb" ])
  end

  it "recognises a migrations folder outside db" do
    verdict = check(paths: %w[packages/api/migrations/0004_orders.sql], declared: [])

    expect(verdict.reasons).to include("data_change")
  end

  it "sends to a person a path the project reserved and the plan never named" do
    project.update!(supporter_reserved_topics: "app/billing/")

    verdict = check(paths: %w[app/billing/invoice.rb], declared: [])

    expect(verdict.reasons).to eq(%w[reserved_path_undeclared])
    expect(verdict.reserved).to eq(%w[app/billing/invoice.rb])
  end

  it "lets through a reserved path the approved plan named" do
    project.update!(supporter_reserved_topics: "app/billing/")

    verdict = check(paths: %w[app/billing/invoice.rb], declared: %w[app/billing/invoice.rb])

    expect(verdict).not_to be_review
  end

  it "counts ordinary files outside the plan without asking for a person" do
    verdict = check(paths: %w[app/models/user.rb app/models/order.rb], declared: %w[app/models/user.rb])

    expect(verdict).not_to be_review
    expect(verdict.outside_plan).to eq(%w[app/models/order.rb])
  end

  it "asks for a person when the file list is incomplete" do
    verdict = check(paths: %w[app/models/user.rb], declared: %w[app/models/user.rb], truncated: true)

    expect(verdict.reasons).to eq(%w[files_unknown])
  end

  it "compares paths without a leading dot or slash" do
    verdict = check(paths: %w[./app/models/user.rb], declared: %w[/app/models/user.rb])

    expect(verdict.outside_plan).to eq([])
  end

  it "reports the score the changed files alone would get" do
    expect(check(paths: %w[app/models/user.rb]).score).to eq(1)
    expect(check(paths: %w[Dockerfile]).score).to eq(Agents::Supporters::RiskScore::ROUTINE_SENSITIVE_PATH)
    expect(check(paths: %w[.kamal/secrets]).score).to eq(Agents::Supporters::RiskScore::SENSITIVE_PATH)
  end

  # CYRA-1292 — tests taken away by the delivery are recorded, never a stop by themselves.
  describe "tests the delivery took away" do
    def check_files(*files)
      described_class.call(paths: files.map { |file| file[:path] }, declared_paths: files.map { |file| file[:path] },
                           organization:, project:, files:)
    end

    it "lists the deleted test files" do
      verdict = check_files({ path: "spec/models/user_spec.rb", status: "removed", additions: 0, deletions: 30 },
                            { path: "app/models/user.rb", status: "modified", additions: 5, deletions: 1 })

      expect(verdict).to have_attributes(review?: false, tests_weakened?: true,
                                         tests_removed: %w[spec/models/user_spec.rb], tests_delta: -30)
    end

    it "sees a test file that lost more lines than it gained" do
      verdict = check_files({ path: "src/cart.test.ts", status: "modified", additions: 2, deletions: 12 })

      expect(verdict).to have_attributes(tests_weakened?: true, tests_removed: [], tests_delta: -10)
    end

    it "says nothing when tests grow" do
      verdict = check_files({ path: "test/cart_test.rb", status: "added", additions: 20, deletions: 0 },
                            { path: "app/models/cart.rb", status: "modified", additions: 1, deletions: 30 })

      expect(verdict).to have_attributes(tests_weakened?: false, tests_delta: 20)
    end

    it "says nothing without line counts" do
      expect(check(paths: %w[spec/models/user_spec.rb])).to have_attributes(tests_weakened?: false, tests_delta: 0)
    end
  end

  it "serialises to a hash a ticket event can keep" do
    record = check(paths: %w[Dockerfile app/models/order.rb], declared: []).to_h

    expect(record).to include(reasons: %w[sensitive_path_undeclared], files_count: 2, outside_plan_count: 2)
  end
end
