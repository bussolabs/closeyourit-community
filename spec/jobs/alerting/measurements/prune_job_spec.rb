# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::PruneJob do
  include ActiveJob::TestHelper

  it "orders equal dates by id, continues batches and preserves the retention boundary" do
    travel_to Time.utc(2026, 11, 23, 12) do
      project = create(:project)
      rule = create(:alerting_rule, project: project, organization: project.organization)
      rows = 1002.times.map do |index|
        { id: format("00000000-0000-0000-0000-%012d", index + 1),
          rule_id: rule.id, project_id: project.id, series_id: SecureRandom.uuid,
          config_digest: "a" * 64, window_end_ns: index, status: "unknown", result: {},
          created_at: 30.days.ago - 1.second, updated_at: Time.current }
      end
      # The highest id is oldest; UUID order alone would leave it behind (CYRA-1231).
      rows.last[:created_at] = 31.days.ago
      Alerting::Evaluation.insert_all!(rows.reverse)
      retained = [ 30.days.ago, 30.days.ago + 1.second, Time.current ].each_with_index.map do |date, index|
        Alerting::Evaluation.create!(rows.first.except(:id).merge(created_at: date, window_end_ns: 2000 + index))
      end

      expect { described_class.perform_now }.to have_enqueued_job(described_class).exactly(:once)
      expect(Alerting::Evaluation.where(id: rows.map { |row| row[:id] }).pluck(:id))
        .to match_array(rows.slice(999, 2).map { |row| row[:id] })
      clear_enqueued_jobs
      expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
      expect(Alerting::Evaluation.where(rule_id: rule.id).pluck(:id)).to match_array(retained.map(&:id))
    end
  end

  it "deletes bounded expired batches and schedules continuation without scheduling new evaluations" do
    project = create(:project)
    rule = create(:alerting_rule, project: project, organization: project.organization)
    rows = 1001.times.map do |index|
      { rule_id: rule.id, project_id: project.id, series_id: SecureRandom.uuid, config_digest: "a" * 64,
        window_end_ns: index, status: "unknown", result: {}, created_at: 31.days.ago, updated_at: 31.days.ago }
    end
    Alerting::Evaluation.insert_all!(rows)
    expect { described_class.perform_now }.to have_enqueued_job(described_class)
    expect(Alerting::Evaluation.where(rule_id: rule.id).count).to eq(1)
    expect(Alerting::Measurements::EvaluateJob).not_to have_been_enqueued
    described_class.perform_now
    expect(Alerting::Evaluation.where(rule_id: rule.id)).to be_empty
  end
end
