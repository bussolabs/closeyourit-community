# frozen_string_literal: true

require "rails_helper"

# The per-minute retry lookup reads only unknown evaluations whose window ended inside
# Evaluate::RETRY_WINDOW; expired ones keep their retry_at and must not come back (CYRA-1231).
RSpec.describe Alerting::Measurements::ScheduleJob do
  let(:now) { Time.utc(2026, 10, 4, 12, 10, 0) }
  let(:project) { create(:project) }
  let(:rule) { create(:alerting_rule, project: project, organization: project.organization) }

  def evaluation_row(window_end:, retry_at:, status: "unknown", config_digest: "a" * 64)
    { rule_id: rule.id, project_id: project.id, series_id: SecureRandom.uuid, config_digest: config_digest,
      window_end_ns: window_end.to_i * 1_000_000_000, status: status, result: {}, retry_at: retry_at,
      created_at: now, updated_at: now }
  end

  it "retries only the recent unknown evaluation whose retry is due" do
    travel_to now do
      Alerting::Evaluation.insert_all!([
        evaluation_row(window_end: now - 2.minutes, retry_at: now - 10.seconds, config_digest: "b" * 64),
        evaluation_row(window_end: now - 1.hour, retry_at: now - 59.minutes),
        evaluation_row(window_end: now - 6.minutes, retry_at: now - 30.seconds),
        evaluation_row(window_end: now - 1.minute, retry_at: now + 30.seconds),
        evaluation_row(window_end: now - 2.minutes, retry_at: nil, status: "firing")
      ])

      expect { described_class.perform_now }.to have_enqueued_job(Alerting::Measurements::EvaluateJob).exactly(:once)
      expect(Alerting::Measurements::EvaluateJob).to have_been_enqueued
        .with(rule_id: rule.id, window_end: (now - 2.minutes).iso8601, config_digest: "b" * 64)
    end
  end

  it "retries at most one batch, oldest retry first" do
    travel_to now do
      rows = (described_class::BATCH_SIZE + 1).times.map do |index|
        evaluation_row(window_end: now - 2.minutes, retry_at: now - (index + 1).seconds, config_digest: format("%064d", index))
      end
      Alerting::Evaluation.insert_all!(rows)

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::Measurements::EvaluateJob).exactly(described_class::BATCH_SIZE).times
      expect(Alerting::Measurements::EvaluateJob).not_to have_been_enqueued
        .with(rule_id: rule.id, window_end: (now - 2.minutes).iso8601, config_digest: format("%064d", 0))
      expect(Alerting::Measurements::EvaluateJob).to have_been_enqueued
        .with(rule_id: rule.id, window_end: (now - 2.minutes).iso8601, config_digest: format("%064d", described_class::BATCH_SIZE))
    end
  end

  it "includes the five-minute boundary but excludes older windows and absent retry dates" do
    travel_to now do
      Alerting::Evaluation.insert_all!([
        evaluation_row(window_end: now - 5.minutes, retry_at: now, config_digest: "b" * 64),
        evaluation_row(window_end: now - 5.minutes - 1.second, retry_at: now),
        evaluation_row(window_end: now - 2.minutes, retry_at: nil)
      ])

      expect { described_class.perform_now }.to have_enqueued_job(Alerting::Measurements::EvaluateJob).exactly(:once)
      expect(Alerting::Measurements::EvaluateJob).to have_been_enqueued
        .with(rule_id: rule.id, window_end: (now - 5.minutes).iso8601, config_digest: "b" * 64)
    end
  end
end
