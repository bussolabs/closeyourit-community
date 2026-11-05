# frozen_string_literal: true

require "rails_helper"

# CYRA-1165 / DOD-6 — the test runs older than the retention go every night, with their results;
# a test no run has named since then goes too. The recent history stays.
RSpec.describe Projects::PruneTestRunsJob do
  let(:project) { create(:project) }
  let(:old_time) { (Projects::TestRun::RETENTION + 1.day).ago }

  it "deletes the old runs with their results and the tests no recent run named" do
    gone = create(:test_case, project:, last_run_at: old_time)
    kept = create(:test_case, project:, last_run_at: 1.day.ago)
    old_run = create(:test_run, project:, ran_at: old_time)
    recent_run = create(:test_run, project:, ran_at: 1.day.ago)
    create(:test_result, test_run: old_run, test_case: gone)
    create(:test_result, test_run: old_run, test_case: kept)
    create(:test_result, test_run: recent_run, test_case: kept)
    create(:known_failure, test_case: gone)

    described_class.perform_now

    expect(Projects::TestRun.all).to contain_exactly(recent_run)
    expect(Projects::TestCase.all).to contain_exactly(kept)
    expect(kept.results.count).to eq(1)
    expect(Projects::KnownFailure.count).to eq(0)
  end

  it "runs every night" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    entry = recurring.fetch("production")["prune_test_runs"]

    expect(entry).to include("class" => described_class.name, "queue" => "batch")
  end
end
